@testable import Emuqu
import XCTest

/// Tests for BaselineTracker
/// Validates baseline deviation logic and interpretation
final class BaselineTrackerTests: XCTestCase {
    /// Files of the trackers this test made, removed in tearDown.
    private var trackerFiles: [URL] = []

    override func tearDownWithError() throws {
        for url in trackerFiles where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        trackerFiles = []
        try super.tearDownWithError()
    }

    /// A tracker on its own empty file in the temporary directory, so no test
    /// reads or overwrites the app's `HRVBaseline.json` or another test's data.
    private func makeTracker() -> BaselineTracker {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("HRVBaseline-\(UUID().uuidString).json")
        trackerFiles.append(file)
        return BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
    }

    // MARK: - Baseline Configuration Tests

    func testBaselineWindowDays() {
        XCTAssertEqual(BaselineTracker.baselineWindowDays, 7)
    }

    func testMaxHistoricalPoints() {
        XCTAssertEqual(BaselineTracker.maxHistoricalPoints, 90)
    }

    func testMinimumSamplesForValidBaseline() {
        XCTAssertEqual(BaselineTracker.Baseline.minimumSamples, 3)
    }

    // MARK: - Producer Tests
    //
    // The z-score scoring anchor is `exp(lnRmssdMean)`, the GEOMETRIC mean of
    // RMSSD. RMSSD is log-normal, so the geometric mean is the correct central
    // tendency; an arithmetic mean would sit above it (Jensen's inequality) and
    // systematically deflate every recovery score. These pin that property and
    // the minimum-days gate. Each tracker starts on its own empty temporary
    // file (`makeTracker()`), never the app's HRVBaseline.json.

    private let producerSchedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)

    private func producerMockSession(daysAgo: Int, rmssd: Double, meanHR: Double = 58.0, hrvDataQuality: HRVDataQuality? = nil) -> HRVSession {
        let calendar = Calendar.current
        let sessionDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let timeDomain = TimeDomainMetrics(
            meanRR: 60000.0 / meanHR, sdnn: 55.0, rmssd: rmssd, pnn50: 20.0,
            sdsd: rmssd * 0.9, meanHR: meanHR, sdHR: 5.0, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        let analysisResult = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: sessionDate
        )
        var session = HRVSession(
            id: UUID(), startDate: sessionDate,
            endDate: sessionDate.addingTimeInterval(28800), state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: analysisResult,
            artifactFlags: nil, recoveryScore: 7.0, tags: [], notes: nil,
            importedMetrics: nil, deviceProvenance: nil, sleepStartMs: nil, sleepEndMs: nil
        )
        session.hrvDataQuality = hrvDataQuality
        return session
    }

    /// An `.insufficient` session (an awake/too-short
    /// partial, e.g. a pre-sleep recording paused while still up) must never
    /// enter the rolling baseline. Its depressed RMSSD would drag the anchor
    /// down and corrupt the NEXT morning's recovery score.
    func testInsufficientSessionsExcludedFromBaseline() throws {
        let tracker = makeTracker()

        var sessions = (0 ..< 8).map { producerMockSession(daysAgo: $0, rmssd: 50) }
        // One extra day with an absurd 5 ms RMSSD that would wreck the anchor
        // if admitted — but it is flagged `.insufficient`, so it must be ignored.
        sessions.append(producerMockSession(daysAgo: 8, rmssd: 5, hrvDataQuality: .insufficient))
        tracker.rebuildFromSessions(sessions, sleepSchedule: producerSchedule)

        let stats = try XCTUnwrap(tracker.recoveryBaselineStats)
        XCTAssertEqual(stats.daysInWindow, 8, "The .insufficient day must not contribute to the baseline")
        XCTAssertEqual(exp(stats.lnRmssdMean), 50.0, accuracy: 0.5,
                       "Anchor must reflect only the good days, unmoved by the insufficient 5 ms partial")
    }

    // MARK: - Structural baseline admission

    /// Builds a session of an explicit duration with no organized-recovery
    /// evidence — the shape a short partial reading actually has.
    private func shortMockSession(daysAgo: Int, rmssd: Double, durationSec: TimeInterval) -> HRVSession {
        let calendar = Calendar.current
        let sessionDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let timeDomain = TimeDomainMetrics(
            meanRR: 60000.0 / 58.0, sdnn: 55.0, rmssd: rmssd, pnn50: 20.0,
            sdsd: rmssd * 0.9, meanHR: 58.0, sdHR: 5.0, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        let analysisResult = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: sessionDate
        )
        return HRVSession(
            id: UUID(), startDate: sessionDate,
            endDate: sessionDate.addingTimeInterval(durationSec), state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: analysisResult,
            artifactFlags: nil, recoveryScore: 7.0, tags: [], notes: nil,
            importedMetrics: nil, deviceProvenance: nil, sleepStartMs: nil, sleepEndMs: nil
        )
    }

    /// The case this gate exists for.
    ///
    /// Without this gate a 30-minute partial with an absurdly HIGH RMSSD sails
    /// into the baseline, because the only other gate in front of it
    /// (`hrvDataQuality`) is deliberately asymmetric — it lets an
    /// above-baseline reading through so the user still sees a number. Short
    /// windows carry the largest positive sampling error, so baseline
    /// admission becomes a one-directional filter: only the samples that
    /// raise the anchor get in, and the ones that would pull it back are
    /// rejected as `.insufficient`.
    ///
    /// The anchor must be unmoved by this session.
    func testShortHighRMSSDPartialIsExcludedFromBaseline() throws {
        let tracker = makeTracker()

        var sessions = (0 ..< 8).map { producerMockSession(daysAgo: $0, rmssd: 50) }
        // 30 minutes, no organized recovery, RMSSD 4x the good days.
        sessions.append(shortMockSession(daysAgo: 8, rmssd: 200, durationSec: 1800))
        tracker.rebuildFromSessions(sessions, sleepSchedule: producerSchedule)

        let stats = try XCTUnwrap(tracker.recoveryBaselineStats)
        XCTAssertEqual(stats.daysInWindow, 8, "A short partial must not contribute, however high its RMSSD")
        XCTAssertEqual(exp(stats.lnRmssdMean), 50.0, accuracy: 0.5,
                       "Anchor must be unmoved by the 200 ms short partial")
    }

    /// The same exclusion must hold with NO baseline established yet — the
    /// first nights are precisely the ones that seed the anchor for the life
    /// of the install, so they cannot be the ones that go ungated.
    func testShortPartialExcludedEvenBeforeABaselineExists() {
        let tracker = makeTracker()

        tracker.rebuildFromSessions(
            [shortMockSession(daysAgo: 0, rmssd: 200, durationSec: 1800)],
            sleepSchedule: producerSchedule
        )
        XCTAssertNil(tracker.recoveryBaselineStats,
                     "A lone short partial must not seed a baseline")
    }

    /// The gate is structural: identical geometry, opposite sides of a typical
    /// baseline, same verdict. This is the property that makes the filter
    /// non-directional and therefore non-compounding.
    func testStructuralGateIgnoresWhichSideOfBaselineTheValueLandsOn() throws {
        for rmssd in [5.0, 200.0] {
            let s = shortMockSession(daysAgo: 0, rmssd: rmssd, durationSec: 1800)
            let result = try XCTUnwrap(s.analysisResult)
            XCTAssertFalse(
                BaselineTracker.isStructurallySoundForBaseline(session: s, result: result),
                "A 30-minute partial is not baseline-quality at RMSSD \(rmssd)"
            )
        }
    }

    /// A full night with the same lack of organized-recovery evidence IS
    /// admitted — the gate is about structure, not about being strict.
    func testFullLengthSessionIsAdmitted() throws {
        let s = shortMockSession(daysAgo: 0, rmssd: 50, durationSec: 28800)
        let result = try XCTUnwrap(s.analysisResult)
        XCTAssertTrue(BaselineTracker.isStructurallySoundForBaseline(session: s, result: result))
    }

    /// The daily report reads its nights from `baselineRMSSDs`, so they must
    /// be the nights the score's baseline holds for the same night: the same
    /// count and ln(RMSSD) mean as `recoveryBaselineStats(excludingNightOf:)`
    /// on a tracker rebuilt from the same sessions, with a short partial,
    /// an unreliable night and the reported night itself among them.
    func testBaselineRMSSDsAreTheNightsTheScoreReads() throws {
        let today = producerMockSession(daysAgo: 0, rmssd: 70)
        var sessions = (1 ... 8).map { producerMockSession(daysAgo: $0, rmssd: 40 + Double($0) * 3) }
        sessions.append(shortMockSession(daysAgo: 9, rmssd: 200, durationSec: 1800))
        sessions.append(producerMockSession(daysAgo: 10, rmssd: 5, hrvDataQuality: .insufficient))
        sessions.append(today)
        let tracker = makeTracker()
        tracker.rebuildFromSessions(sessions, sleepSchedule: producerSchedule)

        let stats = try XCTUnwrap(tracker.recoveryBaselineStats(excludingNightOf: today, sleepSchedule: producerSchedule))
        let nights = BaselineTracker.baselineRMSSDs(rebuiltFrom: sessions, beforeNightOf: today, sleepSchedule: producerSchedule)

        XCTAssertEqual(nights.count, 8)
        XCTAssertEqual(nights.count, stats.daysInWindow)
        XCTAssertEqual(nights.map { log($0) }.reduce(0, +) / Double(nights.count), stats.lnRmssdMean, accuracy: 1e-12)
    }

    private func seededTracker(rmssdValues: [Double]) -> BaselineTracker {
        let tracker = makeTracker()
        // One distinct calendar day per value (daysAgo = index) so each appends.
        let sessions = rmssdValues.enumerated().map { producerMockSession(daysAgo: $0.offset, rmssd: $0.element) }
        tracker.rebuildFromSessions(sessions, sleepSchedule: producerSchedule)
        return tracker
    }

    func testBaselineAnchorIsGeometricMean() throws {
        let values: [Double] = [20, 25, 30, 35, 40, 50, 60, 80, 100, 120]
        let tracker = seededTracker(rmssdValues: values)
        let stats = try XCTUnwrap(tracker.recoveryBaselineStats, "Baseline should exist with 10 days")

        let expectedGeometric = exp(values.map(log).reduce(0, +) / Double(values.count))
        XCTAssertEqual(exp(stats.lnRmssdMean), expectedGeometric, accuracy: 0.01,
                       "Anchor exp(lnRmssdMean) must equal the geometric mean of RMSSD")
        XCTAssertEqual(stats.daysInWindow, values.count)
    }

    func testGeometricMeanIsBelowArithmeticMean() throws {
        // Jensen's inequality: for non-constant positive data the geometric
        // mean is strictly below the arithmetic mean. If this inverts, the
        // anchor has regressed to an arithmetic average and scores deflate.
        let values: [Double] = [20, 25, 30, 35, 40, 50, 60, 80, 100, 120]
        let tracker = seededTracker(rmssdValues: values)
        let stats = try XCTUnwrap(tracker.recoveryBaselineStats)

        let arithmeticMean = values.reduce(0, +) / Double(values.count)
        XCTAssertLessThan(exp(stats.lnRmssdMean), arithmeticMean,
                          "Geometric anchor must sit below the arithmetic mean for skewed data")
    }

    func testConstantData_GeometricEqualsArithmetic() throws {
        let values = Array(repeating: 50.0, count: 8)
        let tracker = seededTracker(rmssdValues: values)
        let stats = try XCTUnwrap(tracker.recoveryBaselineStats)

        XCTAssertEqual(exp(stats.lnRmssdMean), 50.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(stats.lnRmssdSD, BaselineConstants.lnRmssdSDFloor,
                                    "SD must never fall below the floor (division-by-zero guard)")
    }

    func testBelowMinimumDays_ReturnsNil() {
        let values = Array(repeating: 45.0, count: BaselineTracker.RecoveryBaselineStats.minimumDays - 1)
        let tracker = seededTracker(rmssdValues: values)
        XCTAssertNil(tracker.recoveryBaselineStats,
                     "Baseline must be withheld below minimumDays")
    }

    // MARK: - Overnight only, one slot per night, never scored against itself

    private func timedSession(start: Date, hours: Double, rmssd: Double, type: SessionType = .overnight) -> HRVSession {
        let template = producerMockSession(daysAgo: 0, rmssd: rmssd)
        return HRVSession(
            id: UUID(), startDate: start,
            endDate: start.addingTimeInterval(hours * 3600), state: .complete,
            sessionType: type, rrSeries: nil, analysisResult: template.analysisResult,
            artifactFlags: nil, recoveryScore: 7.0, tags: [], notes: nil,
            importedMetrics: nil, deviceProvenance: nil, sleepStartMs: nil, sleepEndMs: nil
        )
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))
        return base ?? Date()
    }

    /// A long, clean quick reading stays out of the baseline even though it has
    /// no `hrvDataQuality` and so would count as reliable. Only overnight readings
    /// describe the resting state the baseline is.
    func testQuickReadingNeverEntersBaseline() {
        let tracker = makeTracker()
        tracker.update(with: timedSession(start: at(1, 15), hours: 8, rmssd: 20, type: .quick), sleepSchedule: producerSchedule)
        tracker.update(with: timedSession(start: at(2, 15), hours: 8, rmssd: 20, type: .nap), sleepSchedule: producerSchedule)
        XCTAssertEqual(tracker.daysCollected, 0)
    }

    /// Slots are nights, not calendar days: a night started at 23:00 and its
    /// 02:30 continuation share one slot, while 02:30 and 23:30 on the same
    /// date (two different nights) take two. Each part is three hours or
    /// more so the structural gate admits it.
    func testSlotsAreKeyedByNightNotCalendarDay() {
        let tracker = makeTracker()
        tracker.update(with: timedSession(start: at(1, 23), hours: 3, rmssd: 50), sleepSchedule: producerSchedule)
        tracker.update(with: timedSession(start: at(2, 2, 30), hours: 4, rmssd: 50), sleepSchedule: producerSchedule)
        XCTAssertEqual(tracker.daysCollected, 1, "One night, one slot")
        tracker.update(with: timedSession(start: at(2, 23, 30), hours: 7, rmssd: 50), sleepSchedule: producerSchedule)
        XCTAssertEqual(tracker.daysCollected, 2, "02:30 and 23:30 on June 2 are different nights")
    }

    /// The saved score's baseline excludes the night being scored: the
    /// scoring stats leave that night's slot out.
    func testScoringStatsExcludeTheScoredNight() throws {
        let tracker = makeTracker()
        for day in 1 ... 4 {
            tracker.update(with: timedSession(start: at(day, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)
        }
        let scored = timedSession(start: at(5, 23), hours: 8, rmssd: 160)
        tracker.update(with: scored, sleepSchedule: producerSchedule)

        let all = try XCTUnwrap(tracker.recoveryBaselineStats)
        let forScoring = try XCTUnwrap(tracker.recoveryBaselineStats(excludingNightOf: scored, sleepSchedule: producerSchedule))
        XCTAssertEqual(all.daysInWindow, 5)
        XCTAssertEqual(forScoring.daysInWindow, 4)
        XCTAssertEqual(exp(forScoring.lnRmssdMean), 40.0, accuracy: 0.01, "The 160 ms night must not anchor its own score")
    }

    /// Re-scoring an old night reads only the nights before it, as the
    /// published method builds its reference from earlier days.
    func testScoringStatsIgnoreLaterNights() throws {
        let tracker = makeTracker()
        for day in 1 ... 3 {
            tracker.update(with: timedSession(start: at(day, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)
        }
        let scored = timedSession(start: at(4, 23), hours: 8, rmssd: 40)
        tracker.update(with: scored, sleepSchedule: producerSchedule)
        for day in 5 ... 7 {
            tracker.update(with: timedSession(start: at(day, 23), hours: 8, rmssd: 160), sleepSchedule: producerSchedule)
        }

        let forScoring = try XCTUnwrap(tracker.recoveryBaselineStats(excludingNightOf: scored, sleepSchedule: producerSchedule))
        XCTAssertEqual(forScoring.daysInWindow, 3)
        XCTAssertEqual(exp(forScoring.lnRmssdMean), 40.0, accuracy: 0.01, "Later 160 ms nights must not shift an earlier night's score")
    }

    // MARK: - Persistence

    /// A file that does not decode is moved aside as `.corrupt` before the
    /// tracker saves; the set-aside copy an earlier failure left is replaced
    /// by the new one only once it is in place.
    func testAnUndecodableFileIsSetAsideAndReplacesTheEarlierCopy() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HRVBaseline-\(UUID().uuidString).json")
        let aside = file.appendingPathExtension("corrupt")
        trackerFiles += [file, aside]
        try Data("earlier unreadable copy".utf8).write(to: aside)
        try Data("not a baseline".utf8).write(to: file)

        let tracker = BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
        XCTAssertEqual(try Data(contentsOf: aside), Data("not a baseline".utf8))
        tracker.update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)

        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 1,
                       "Once the file is set aside the tracker saves as usual")
    }

    /// While an undecodable file cannot be moved aside it is the only copy of
    /// what it held, so no save writes over it; the move is tried again on
    /// the next save, and the night is saved once it succeeds.
    func testAnUndecodableFileThatCannotBeSetAsideIsNeverWrittenOver() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("BaselineHold-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        trackerFiles.append(directory)
        let file = directory.appendingPathComponent("HRVBaseline.json")
        let garbage = Data("not a baseline".utf8)
        try garbage.write(to: file)
        // A read-only directory: nothing in it can be renamed or created.
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        addTeardownBlock {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            } catch {
                // swallow-ok: tearDown removes what it can; the directory is temporary.
            }
        }

        let tracker = BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
        tracker.update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)
        XCTAssertEqual(try Data(contentsOf: file), garbage, "The only copy of the unreadable baseline was written over")

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        tracker.update(with: timedSession(start: at(2, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)

        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("corrupt")), garbage,
                       "The unreadable baseline must be set aside before the first save")
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 2,
                       "Both nights are saved once the file is set aside")
    }

    /// A baseline file path in the temporary directory, removed (with any
    /// copy set aside beside it) in tearDown.
    private func sealedBaselineFile() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HRVBaseline-\(UUID().uuidString).json")
        trackerFiles += [file, file.appendingPathExtension("corrupt")]
        return file
    }

    /// The stored nights are sealed with the app's key, never written as
    /// plain JSON, and a tracker started on the file reads them back.
    func testTheBaselineFileIsSealedAndReadsBack() throws {
        let file = sealedBaselineFile()
        BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
            .update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)

        XCTAssertNotEqual(try Data(contentsOf: file).first, UInt8(ascii: "{"), "The nights were written as plain JSON")
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 1)
    }

    /// A plain baseline file an older build wrote still loads, and the next
    /// save replaces it sealed with every night kept.
    func testAPlainBaselineFileFromAnOlderBuildLoadsAndIsResealed() throws {
        let file = sealedBaselineFile()
        let nights = (1 ... 3).map { day in
            #"{"date":"2026-01-0\#(day)T23:00:00Z","rmssd":40,"sdnn":55,"meanHR":58}"#
        }
        try Data(#"{"historicalData":[\#(nights.joined(separator: ","))]}"#.utf8).write(to: file)

        let tracker = BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
        XCTAssertEqual(tracker.daysCollected, 3)
        tracker.update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)

        XCTAssertNotEqual(try Data(contentsOf: file).first, UInt8(ascii: "{"), "The older plain file was not replaced sealed")
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 4)
    }

    /// A sealed baseline whose key is locked at load (before the first
    /// unlock) is never written over or set aside: a night taken meanwhile
    /// waits in memory and is merged onto the file's nights once it opens.
    func testALockedKeyNeverWritesOverTheSealedBaseline() throws {
        let file = sealedBaselineFile()
        BaselineTracker(baselineFile: file, onBaselineUpdated: nil)
            .update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)
        let sealedBytes = try Data(contentsOf: file)
        let key = LockedKeySeal()

        let tracker = BaselineTracker(baselineFile: file, seal: key.fileSeal, onBaselineUpdated: nil)
        tracker.update(with: timedSession(start: at(2, 23), hours: 8, rmssd: 42), sleepSchedule: producerSchedule)
        XCTAssertEqual(try Data(contentsOf: file), sealedBytes, "The sealed baseline was written over while the key was locked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path),
                       "A locked file is not an undecodable one")

        key.setLocked(false)
        tracker.update(with: timedSession(start: at(3, 23), hours: 8, rmssd: 44), sleepSchedule: producerSchedule)
        XCTAssertEqual(tracker.daysCollected, 3)
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 3,
                       "The night taken while the key was locked was not saved")
    }

    /// A save while the key cannot be read writes nothing, never the nights
    /// in plain JSON, and the file keeps the previous save; the next save
    /// writes every night held in memory.
    func testASaveWithTheKeyLockedKeepsThePreviousFile() throws {
        let file = sealedBaselineFile()
        let key = LockedKeySeal()
        key.setLocked(false)
        let tracker = BaselineTracker(baselineFile: file, seal: key.fileSeal, onBaselineUpdated: nil)
        tracker.update(with: timedSession(start: at(1, 23), hours: 8, rmssd: 40), sleepSchedule: producerSchedule)
        let sealedBytes = try Data(contentsOf: file)

        key.setLocked(true)
        tracker.update(with: timedSession(start: at(2, 23), hours: 8, rmssd: 42), sleepSchedule: producerSchedule)
        XCTAssertEqual(try Data(contentsOf: file), sealedBytes, "The file changed while the key was locked")

        key.setLocked(false)
        tracker.update(with: timedSession(start: at(3, 23), hours: 8, rmssd: 44), sleepSchedule: producerSchedule)
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 3)
    }

    /// The decision a failed read of the baseline file makes: a file that may
    /// be intact (protection-locked, an I/O error, out of file descriptors)
    /// holds saves, so the stored nights are not written over; only a file
    /// that is gone or is a directory lets saves go ahead.
    func testOnlyAReadThatCanNeverSucceedLetsSavesWriteOverTheBaseline() {
        func posix(_ code: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
        XCTAssertTrue(BaselineTracker.holdsSaves(afterReadError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(BaselineTracker.holdsSaves(afterReadError: posix(EIO)))
        XCTAssertTrue(BaselineTracker.holdsSaves(afterReadError: posix(EMFILE)))
        XCTAssertFalse(BaselineTracker.holdsSaves(afterReadError: posix(EISDIR)))
        XCTAssertFalse(BaselineTracker.holdsSaves(afterReadError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }

    // MARK: - Callers

    /// The collector's scoring path (`scoringBaselineStats(for:)` and the
    /// readiness baseline in `ansConfig(for:)`) re-scores night N against the
    /// nights before it: night N's own reading and night N+1, both in the
    /// archive, leave it unchanged.
    @MainActor
    func testCollectorRescoresANightAgainstOnlyTheNightsBeforeIt() throws {
        let tracker = makeTracker()
        let archiveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BaselineCallers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }
        let collector = RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager(),
            archive: SessionArchive(directory: archiveDirectory), baselineTracker: tracker
        )
        let schedule = collector.settingsManager.settings.sleepSchedule
        for day in 1 ... 3 {
            tracker.update(with: timedSession(start: at(day, 23), hours: 8, rmssd: 40), sleepSchedule: schedule)
        }
        let nightN = timedSession(start: at(4, 23), hours: 8, rmssd: 160)
        let before = try XCTUnwrap(collector.scoringBaselineStats(for: nightN))
        tracker.update(with: nightN, sleepSchedule: schedule)
        tracker.update(with: timedSession(start: at(5, 23), hours: 8, rmssd: 160), sleepSchedule: schedule)

        let after = try XCTUnwrap(collector.scoringBaselineStats(for: nightN))
        XCTAssertEqual(tracker.daysCollected, 5)
        XCTAssertEqual(after.daysInWindow, before.daysInWindow)
        XCTAssertEqual(after.lnRmssdMean, before.lnRmssdMean, accuracy: 1e-12, "Night N and N+1 must not shift night N's baseline")
        XCTAssertEqual(collector.ansConfig(for: nightN).baselineRMSSD, 40, accuracy: 0.01, "Readiness reads the same prior-nights baseline")
    }
}
