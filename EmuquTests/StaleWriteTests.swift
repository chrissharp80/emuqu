import CryptoKit
@testable import Emuqu
import XCTest

/// Writes that land after a suspension keep what changed meanwhile: the
/// α1 re-analysis keeps samples rewritten during its recompute, a live
/// backup delete keeps the session awaiting deletion when an upload landed
/// during it, a stale review leaves another night's review ids alone, and
/// sessions sealed with another phone's key are counted, said and kept.
@MainActor
final class StaleWriteTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StaleWriteTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that wrote nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func beats(_ count: Int) -> RRSeries {
        let id = UUID()
        return RRSeries(points: (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }, sessionId: id, startDate: Date())
    }

    private func workout(beats series: RRSeries, samples: [WorkoutSample]) -> HRVSession {
        var session = HRVSession(sessionType: .workout)
        session.rrSeries = series
        var metadata = WorkoutMetadata(sport: .run)
        metadata.samples = samples
        session.workoutMetadata = metadata
        return session
    }

    private let reading = WorkoutAlpha1Reanalyzer.Reading(offsetSec: 20, alpha1: 0.8, fitQualityR2: 0.9, cadenceSec: 20)

    // MARK: - α1 re-analysis

    /// The readings go onto the samples stored at the write, which a retrim
    /// rewrote during the recompute, not onto the samples read before it.
    func testReanalysisKeepsSamplesRewrittenDuringTheRecompute() {
        let series = beats(300)
        let basis = workout(beats: series, samples: [WorkoutSample(offsetSec: 0, heartRate: 120), WorkoutSample(offsetSec: 30, heartRate: 130)])
        var stored = workout(beats: series, samples: [WorkoutSample(offsetSec: 30, heartRate: 150)])

        FitnessSummaryCards.applyReanalysis([reading], computedFrom: basis, to: &stored)

        let samples = stored.workoutMetadata?.samples ?? []
        XCTAssertEqual(samples.map(\.offsetSec), [30], "the retrimmed samples stay")
        XCTAssertEqual(samples.first?.heartRate, 150)
        XCTAssertEqual(samples.first?.alpha1, 0.8)
    }

    /// Readings computed from beats the stored copy no longer holds are not
    /// written onto it: they are computed again from the stored beats.
    func testReanalysisDoesNotApplyReadingsFromOtherBeats() {
        let basis = workout(beats: beats(300), samples: [WorkoutSample(offsetSec: 30, heartRate: 130)])
        var stored = workout(beats: beats(10), samples: [WorkoutSample(offsetSec: 30, heartRate: 130)])

        FitnessSummaryCards.applyReanalysis([reading], computedFrom: basis, to: &stored)

        XCTAssertNil(stored.workoutMetadata?.samples?.first?.alpha1)
    }

    // MARK: - Live backup delete

    func testADeleteKeepsTheSessionAwaitingDeletionWhenAnUploadLandedDuringIt() {
        XCTAssertFalse(CloudKitLiveBackupManager.keepsAwaitingDeletion(savedBefore: 2, savedNow: 2))
        XCTAssertTrue(CloudKitLiveBackupManager.keepsAwaitingDeletion(savedBefore: 2, savedNow: 3))
        XCTAssertTrue(CloudKitLiveBackupManager.keepsAwaitingDeletion(savedBefore: 0, savedNow: 1))
    }

    // MARK: - Review ids

    /// A night saved for review after another session took the recorder
    /// (its caller's claim went stale) is saved, but that session's review
    /// does not point at it.
    func testAStaleReviewSaveLeavesTheReviewIdsOfTheSessionOnTheRecorder() throws {
        try requireEncryptionKey()
        let archive = SessionArchive(directory: directory)
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let start = Date().addingTimeInterval(-9 * 3600)
        let night = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(7 * 3600), state: .complete,
            sessionType: .overnight, rrSeries: beats(200), analysisResult: nil, artifactFlags: nil
        )
        collector.sessionState.currentSession = HRVSession(sessionType: .overnight)

        collector.morning.archiveForReview(night)

        XCTAssertTrue(archive.store.exists(night.id), "the night is saved")
        XCTAssertNil(collector.sessionState.reviewArchivedSessionId)
        XCTAssertNil(collector.sessionState.reviewFoldedIntoSessionId)
    }

    // MARK: - Sessions sealed with another phone's key

    func testOnlyAKeyThatCannotOpenTheFileCountsAsAnotherPhonesKey() {
        XCTAssertTrue(SessionArchive.isSealedWithAnotherKey(CryptoKitError.authenticationFailure))
        XCTAssertTrue(SessionArchive.isSealedWithAnotherKey(EncryptionManager.EncryptionError.keyNotFound))
        XCTAssertFalse(SessionArchive.isSealedWithAnotherKey(EncryptionManager.EncryptionError.keychainError(-25308)), "a locked Keychain opens the file later")
        XCTAssertFalse(SessionArchive.isSealedWithAnotherKey(CocoaError(.coderReadCorrupt)))
    }

    /// A session file sealed with a key this phone does not hold is counted
    /// and kept byte for byte; the readable history is untouched.
    func testASessionSealedWithAnotherKeyIsCountedAndKept() throws {
        try requireEncryptionKey()
        let archive = SessionArchive(directory: directory)
        let readable = HRVSession(
            id: UUID(), startDate: Date().addingTimeInterval(-30 * 3600), endDate: Date().addingTimeInterval(-23 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: beats(200), analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(readable, skipSameNightMerge: true)
        let foreign = try AES.GCM.seal(Data("{}".utf8), using: SymmetricKey(size: .bits256)).combined ?? Data()
        let sealed = Data([0x46, 0x52, EncryptionManager.currentKeyVersion]) + foreign
        let file = archive.archiveDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try sealed.write(to: file)

        archive.boot()

        XCTAssertEqual(archive.sealedWithAnotherKeyCount, 1)
        XCTAssertEqual(try Data(contentsOf: file), sealed, "the unreadable night is kept as it was")
        XCTAssertNotNil(try archive.retrieve(readable.id))
    }

    func testNoSessionSealedWithAnotherKeyCountsNone() throws {
        try requireEncryptionKey()
        let archive = SessionArchive(directory: directory)
        try FileManager.default.createDirectory(at: archive.archiveDirectory, withIntermediateDirectories: true)
        try Data("{ not a session".utf8).write(to: archive.archiveDirectory.appendingPathComponent("\(UUID().uuidString).json"))

        archive.boot()

        XCTAssertEqual(archive.sealedWithAnotherKeyCount, 0, "a file that is not sealed is not another phone's")
    }
}
