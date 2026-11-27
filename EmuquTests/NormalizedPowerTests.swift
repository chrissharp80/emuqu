@testable import Emuqu
import XCTest

/// Tests for normalized power.
///
/// NP is the Coggan metric that says how hard a ride
/// actually was: a 30-second rolling mean, raised to the fourth power,
/// averaged, then fourth-rooted. The fourth power is the whole point — it
/// weights surges far above steady effort, so a ride with the same average
/// power scores higher when it was ragged. Getting it wrong misstates the
/// intensity of every ride and everything derived from it.
@MainActor
final class NormalizedPowerTests: XCTestCase {
    private func samples(_ watts: [Int]) -> [WorkoutSample] {
        watts.enumerated().map { i, w in
            WorkoutSample(offsetSec: i, powerWatts: w)
        }
    }

    // MARK: - The window requirement

    func testFewerThanThirtySamplesHasNoNormalizedPower() {
        // One full 30-second window is the minimum the definition allows.
        // Returning a number from 29 samples would be an invented figure.
        XCTAssertNil(WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 29))))
    }

    func testExactlyThirtySamplesProducesAValue() {
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 30)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    func testNoSamplesAtAllIsNil() {
        XCTAssertNil(WorkoutSessionLifecycle.computeNormalizedPower(samples: []))
    }

    func testSamplesWithoutPowerAreExcluded() {
        // A ride with no power meter must not produce a power figure.
        let noPower = (0 ..< 60).map { WorkoutSample(offsetSec: $0) }
        XCTAssertNil(WorkoutSessionLifecycle.computeNormalizedPower(samples: noPower))
    }

    func testMixedSamplesUseOnlyThoseWithPower() {
        // 40 with power, 40 without. The 40 with power clear the 30 threshold.
        var mixed = samples(Array(repeating: 250, count: 40))
        mixed += (0 ..< 40).map { WorkoutSample(offsetSec: 100 + $0) }
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: mixed)
        XCTAssertEqual(np ?? 0, 250, accuracy: 0.001, "gaps must not drag the figure down")
    }

    // MARK: - Gaps in the time axis

    /// The recorder jumps the offset after a suspension and samples none of
    /// the seconds in between. 15 powered seconds before such a gap and 15
    /// after are not 30 seconds of power, so there is no 30-second window.
    func testFifteenSecondsEitherSideOfAnOffsetGapIsNoWindow() {
        let before = (0 ..< 15).map { WorkoutSample(offsetSec: $0, powerWatts: 400) }
        let after = (300 ..< 315).map { WorkoutSample(offsetSec: $0, powerWatts: 400) }
        XCTAssertNil(WorkoutSessionLifecycle.computeNormalizedPower(samples: before + after))
    }

    /// Two 30-second stretches across an offset gap are two separate
    /// windows, none of them mixing seconds from both sides:
    /// ((100^4 + 300^4) / 2)^0.25.
    func testWindowsDoNotSpanAnOffsetGap() throws {
        let before = (0 ..< 30).map { WorkoutSample(offsetSec: $0, powerWatts: 100) }
        let after = (100 ..< 130).map { WorkoutSample(offsetSec: $0, powerWatts: 300) }
        let np = try XCTUnwrap(WorkoutSessionLifecycle.computeNormalizedPower(samples: before + after))
        XCTAssertEqual(np, pow((pow(100.0, 4) + pow(300.0, 4)) / 2, 0.25), accuracy: 1e-9)
    }

    /// A row repeating an offset is the same second again; the first reading
    /// for that second is the one used.
    func testARepeatedOffsetIsTheSameSecond() throws {
        var rows = samples(Array(repeating: 200, count: 30))
        rows.insert(WorkoutSample(offsetSec: 15, powerWatts: 1_000), at: 16)
        let np = try XCTUnwrap(WorkoutSessionLifecycle.computeNormalizedPower(samples: rows))
        XCTAssertEqual(np, 200, accuracy: 1e-9)
    }

    // MARK: - Steady effort

    func testConstantPowerEqualsThatPower() {
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 60)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    // MARK: - The fourth power is what makes NP useful

    func testSurgesPushNormalizedPowerAboveTheAverage() {
        // 90s at 100 W then 30s at 500 W — average 200 W, but the ride was
        // nothing like a steady 200 W effort. NP must say so.
        let ragged = Array(repeating: 100, count: 90) + Array(repeating: 500, count: 30)
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(ragged)) ?? 0
        let average = Double(ragged.reduce(0, +)) / Double(ragged.count)
        XCTAssertEqual(average, 200, accuracy: 0.001, "fixture sanity: the average really is 200")
        XCTAssertEqual(np, 273.1329, accuracy: 0.01)
        XCTAssertGreaterThan(np, average, "a ragged ride must score above its own average")
    }

    /// Fast alternation is smoothed away by the 30-second window, which is why
    /// the window exists: NP measures sustained surges, not sample-to-sample
    /// noise. Same average, same NP.
    func testRapidAlternationIsSmoothedByTheWindow() {
        let alternating = (0 ..< 120).map { $0.isMultiple(of: 2) ? 300 : 100 }
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(alternating)) ?? 0
        XCTAssertEqual(np, 200, accuracy: 0.01, "30s smoothing removes alternation")
    }

    func testLongerSurgesScoreHigherThanShorterOnes() {
        let shortSurge = Array(repeating: 100, count: 110) + Array(repeating: 500, count: 10)
        let longSurge = Array(repeating: 100, count: 80) + Array(repeating: 500, count: 40)
        let shortNP = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(shortSurge)) ?? 0
        let longNP = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(longSurge)) ?? 0
        XCTAssertGreaterThan(longNP, shortNP, "a longer surge is a harder ride")
    }

    // MARK: - Degenerate power

    func testZeroPowerThroughoutIsZeroNotNil() {
        // Coasting is a real reading, distinct from "no power meter".
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 0, count: 60)))
        XCTAssertEqual(np ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - FTP auto-estimate: best 20-minute mean power

    private func steady(_ watts: Int, seconds: Int, from start: Int = 0) -> [WorkoutSample] {
        (start ..< start + seconds).map { WorkoutSample(offsetSec: $0, powerWatts: watts) }
    }

    /// The estimate used whole-session NP, so a hard 20 minutes inside an
    /// easy hour read as the hour's average. It is the best 20-minute window.
    func testTheBestTwentyMinutesIsFoundInsideALongerSession() throws {
        let session = steady(150, seconds: 1_200) + steady(300, seconds: 1_200, from: 1_200) + steady(150, seconds: 1_200, from: 2_400)
        let best = try XCTUnwrap(FTPAutoEstimator.bestTwentyMinuteMeanPower(session))
        XCTAssertEqual(best, 300, accuracy: 1e-9)
    }

    func testUnderTwentyMinutesOfPowerHasNoEstimate() {
        XCTAssertNil(FTPAutoEstimator.bestTwentyMinuteMeanPower(steady(300, seconds: 1_199)))
    }

    /// A window with long gaps in the power stream isn't a 20-minute effort.
    func testAWindowWithTooFewPowerReadingsDoesNotCount() {
        let sparse = steady(300, seconds: 1_200).enumerated().map { i, sample in
            i.isMultiple(of: 5) ? WorkoutSample(offsetSec: sample.offsetSec, powerWatts: nil) : sample
        }
        XCTAssertNil(FTPAutoEstimator.bestTwentyMinuteMeanPower(sparse))
    }

    /// Coasting at 0 W is part of a 20-minute effort, as in Coggan's
    /// mean-maximal power: 1,080 s at 300 W and 120 s at 0 W is a 270 W mean
    /// and a 257 W FTP, not 300 W and 285 W.
    func testZeroWattSecondsCountInTheTwentyMinuteMean() throws {
        let session = steady(300, seconds: 540) + steady(0, seconds: 120, from: 540) + steady(300, seconds: 540, from: 660)
        let best = try XCTUnwrap(FTPAutoEstimator.bestTwentyMinuteMeanPower(session))
        XCTAssertEqual(best, 270, accuracy: 1e-9)
        XCTAssertEqual(FTPAutoEstimator.ftp(for: .init(meanPowerWatts: best, sessionId: UUID())), 257)
    }

    /// A missing reading is not a zero: 1,080 s at 300 W and 120 s with no
    /// reading is a 300 W mean over the seconds that have one.
    func testMissingSecondsAreLeftOutOfTheTwentyMinuteMean() throws {
        let gap = (540 ..< 660).map { WorkoutSample(offsetSec: $0, powerWatts: nil) }
        let session = steady(300, seconds: 540) + gap + steady(300, seconds: 540, from: 660)
        let best = try XCTUnwrap(FTPAutoEstimator.bestTwentyMinuteMeanPower(session))
        XCTAssertEqual(best, 300, accuracy: 1e-9)
    }

    /// TrainingPeaks / Coggan: FTP is 95 % of the best 20-minute mean.
    func testFTPIsNinetyFivePercentOfTheBestTwentyMinutes() {
        XCTAssertEqual(FTPAutoEstimator.ftp(for: .init(meanPowerWatts: 300, sessionId: UUID())), 285)
    }

    func testTheStrongestWorkoutAnchorsTheEstimate() throws {
        func run(_ watts: Int) -> HRVSession {
            var meta = WorkoutMetadata(sport: .run)
            meta.samples = steady(watts, seconds: 1_500)
            var session = HRVSession(startDate: Date(), sessionType: .workout)
            session.workoutMetadata = meta
            return session
        }
        let strongest = run(280)
        let best = try XCTUnwrap(FTPAutoEstimator.bestEffort(in: [run(220), strongest, run(250)]))
        XCTAssertEqual(best.sessionId, strongest.id)
        XCTAssertEqual(best.meanPowerWatts, 280, accuracy: 1e-9)
    }

    func testNoQualifyingWorkoutGivesNoEffort() {
        XCTAssertNil(FTPAutoEstimator.bestEffort(in: []))
    }

    /// Before, a scan whose workouts failed to decode found nothing, cleared
    /// the cached FTP and was stamped, so no re-scan ran for a week. An
    /// incomplete scan now never clears or lowers the estimate; it stores
    /// only a better effort.
    func testAnIncompleteScanNeverClearsOrLowersTheEstimate() {
        let effort = FTPAutoEstimator.Effort(meanPowerWatts: 300, sessionId: UUID())
        XCTAssertFalse(FTPAutoEstimator.incompleteScanStores(nil, cachedFTP: 280))
        XCTAssertFalse(FTPAutoEstimator.incompleteScanStores(effort, cachedFTP: 290))
        XCTAssertTrue(FTPAutoEstimator.incompleteScanStores(effort, cachedFTP: 280))
        XCTAssertTrue(FTPAutoEstimator.incompleteScanStores(effort, cachedFTP: nil))
    }

    /// Before, any workout that could not be read kept the FTP scan (and the
    /// workout-load backfill) from being stamped, so one corrupt file reran
    /// both scans on every launch for good. Only a failure that clears once
    /// the device is unlocked or space is freed keeps a scan open now.
    /// A workout imported or restored after the last scan can be dated weeks
    /// before it. Compared by date, it never triggered a rescan; by id, it
    /// does. One the scan read does not.
    func testAWorkoutTheLastScanDidNotReadTriggersARescan() {
        let (read, imported) = (UUID(), UUID())
        XCTAssertTrue(FTPAutoEstimator.hasUnscannedWorkout([read, imported], scanned: [read.uuidString]))
        XCTAssertFalse(FTPAutoEstimator.hasUnscannedWorkout([read], scanned: [read.uuidString]))
        XCTAssertTrue(FTPAutoEstimator.hasUnscannedWorkout([read], scanned: nil), "no ids recorded: scan once")
    }

    func testOnlyAFailureThatMayClearKeepsALaunchScanOpen() {
        let lockedFile = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let lockedUnderneath = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        let clearing: [any Error] = [
            EncryptionManager.EncryptionError.keychainError(-25_308), lockedFile, lockedUnderneath,
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        ]
        for error in clearing {
            XCTAssertTrue(ArchiveAccessFailure.mayClear(error), "\(error)")
        }
        let corrupt = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "corrupt"))
        let lasting: [any Error] = [
            SessionArchive.ArchiveError.hashMismatch, SessionArchive.ArchiveError.fileNotFound,
            SessionArchive.ArchiveError.newerSchemaVersion(99), EncryptionManager.EncryptionError.decryptionFailed,
            EncryptionManager.EncryptionError.keyNotFound, corrupt,
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        ]
        for error in lasting {
            XCTAssertFalse(ArchiveAccessFailure.mayClear(error), "\(error)")
        }
    }

    // MARK: - Concept2 PM5 stroke power (Additional Stroke Data 0x0036)

    private func strokePacket(power: UInt16, strokes: UInt16) -> Data {
        Data([0x10, 0x27, 0x00, UInt8(power & 0xFF), UInt8(power >> 8), 0x2C, 0x01,
              UInt8(strokes & 0xFF), UInt8(strokes >> 8), 0, 0, 0, 0, 0, 0])
    }

    /// Power was read from bytes 16–17 of 0x0032, which the PM5 sends as 17
    /// bytes, so a row never recorded power. It is bytes 3–4 of 0x0036.
    func testStrokePowerAndCountAreDecodedFromTheStrokePacket() throws {
        let stroke = try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 245, strokes: 312)))
        XCTAssertEqual(stroke.powerWatts, 245)
        XCTAssertEqual(stroke.strokeCount, 312)
    }

    func testImplausibleStrokePowerIsDropped() throws {
        XCTAssertNil(try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 0, strokes: 1))).powerWatts)
        XCTAssertNil(try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 4_000, strokes: 1))).powerWatts)
    }

    func testAShortStrokePacketIsIgnored() {
        XCTAssertNil(Concept2Manager.strokeData(from: Data([0, 0, 0, 1, 0])))
    }

    // MARK: - Foot pod and trainer power

    /// Coasting reads 0 W and is a reading; a meter that has gone quiet
    /// without dropping the link has no current reading, rather than its
    /// last watts counted every second.
    func testZeroWattsCountsAndAStaleReadingDoesNot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FootPodManager.fresh(0, measuredAt: now, now: now), 0)
        XCTAssertEqual(FootPodManager.fresh(240, measuredAt: now.addingTimeInterval(-2), now: now), 240)
        XCTAssertNil(FootPodManager.fresh(240, measuredAt: now.addingTimeInterval(-(FootPodManager.readingStaleAfter + 1)), now: now))
        XCTAssertNil(FootPodManager.fresh(nil, measuredAt: now, now: now))
    }

    /// A 0 W reading is plotted on the power chart; a row without power is not.
    func testThePowerChartPlotsZeroWattsAndSkipsMissingRows() {
        let rows = [
            WorkoutSample(offsetSec: 0, powerWatts: 250), WorkoutSample(offsetSec: 60, powerWatts: 0),
            WorkoutSample(offsetSec: 120, powerWatts: nil)
        ]
        let points = WorkoutStatsCards.powerChartPoints(rows)
        XCTAssertEqual(points.map(\.0), [0, 1])
        XCTAssertEqual(points.map(\.1), [250, 0])
    }

    /// The live fact sheet reports 0 W as a reading; only a connected pod
    /// with no current reading is silent.
    func testTheLivePowerLineReportsZeroWatts() {
        XCTAssertEqual(WorkoutAIContext.powerLine(0, footPodActive: true), "powerW=0")
        XCTAssertEqual(WorkoutAIContext.powerLine(0, footPodActive: false), "powerW=0")
        XCTAssertEqual(WorkoutAIContext.powerLine(nil, footPodActive: true), "powerW=silent")
        XCTAssertNil(WorkoutAIContext.powerLine(nil, footPodActive: false))
    }

    /// A coasting stretch of 0 W rows stays one run for the 30-second
    /// windows, so normalized power counts the easy seconds as easy.
    func testCoastingAtZeroWattsKeepsTheWindowsWhole() {
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 30) + Array(repeating: 0, count: 30)))
        let steady = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 60)))
        XCTAssertNotNil(np)
        XCTAssertLessThan(np ?? .infinity, steady ?? 0)
    }
}
