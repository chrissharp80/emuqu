@testable import Emuqu
import XCTest

/// An edit that changes a night's beats or span commits a night whose
/// derived fields describe what it holds (`NightBeatsEdit`): flags cleared,
/// the window moved with its beats, the span following the beats' tail, a
/// window the user picked kept only while all of its beats are, and then a
/// reanalysis asked for. A fold of two recordings of one night asks for it.
final class NightBeatsEditTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NightBeatsEditTests-\(UUID().uuidString)", isDirectory: true)
    private let start = Date(timeIntervalSince1970: 4_102_444_800)

    override func tearDown() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        super.tearDown()
    }

    /// Two hours of beats with an analysis over beats 100 ..< 300 that the
    /// user picked, flags on every beat, and sleep to the end.
    private func pickedNight() -> HRVSession {
        var night = MergeClockFixture.session(start: start, minutes: 120, meanRR: 1000, withAnalysis: true)
        night.windowUserAdjusted = true
        night.artifactFlags = [ArtifactFlags](repeating: .clean, count: night.rrSeries?.points.count ?? 0)
        night.sleepStartMs = 0
        night.sleepEndMs = 120 * 60_000
        return night
    }

    /// The last hour removed: the night ends at its last kept beat, its
    /// sleep inside that, its flags gone; the picked window, in the first
    /// minutes, is kept.
    func testRemovingTheTailEndsTheNightAtItsLastBeatAndKeepsAPickedWindowItStillHolds() throws {
        var night = pickedNight()
        let kept = (night.rrSeries?.points ?? []).filter { $0.t_ms < 60 * 60_000 }

        NightBeatsEdit.replaceBeats(of: &night, with: kept)

        XCTAssertNil(night.artifactFlags)
        XCTAssertEqual(try XCTUnwrap(night.endDate).timeIntervalSince(start), 3_600, accuracy: 5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(night.sleepEndMs), 3_605_000)
        XCTAssertEqual(night.windowUserAdjusted, true)
        XCTAssertEqual(night.rrSeries?.points.count, kept.count)
    }

    /// Beats inside the picked window removed: the pick no longer describes
    /// the night, so the mark goes and the reanalysis chooses again.
    func testRemovingBeatsOfAPickedWindowDropsThePick() {
        var night = pickedNight()
        let points = night.rrSeries?.points ?? []
        let kept = points.enumerated().filter { !(150 ..< 250).contains($0.offset) }.map(\.element)

        NightBeatsEdit.replaceBeats(of: &night, with: kept)

        XCTAssertNil(night.windowUserAdjusted)
    }

    /// A longer tail, as the strap's own recording gives, extends the night.
    func testALongerTailExtendsTheNight() throws {
        var night = MergeClockFixture.session(start: start, minutes: 60, meanRR: 1000)
        let longer = MergeClockFixture.points(minutes: 90, meanRR: 1000)

        NightBeatsEdit.replaceBeats(of: &night, with: longer)

        XCTAssertEqual(try XCTUnwrap(night.endDate).timeIntervalSince(start), 5_400, accuracy: 5)
    }

    private var lastNight: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600) }

    private func recording(from start: Date, hours: Double, rr: Int) -> HRVSession {
        let id = UUID()
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? rr - 10 : rr + 10) }
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(hours * 3600), state: .complete,
            sessionType: .overnight, rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }

    /// A second recording folded into a night changes its beats, so the
    /// night is asked to be analysed again from them.
    func testAFoldAsksForTheNightToBeAnalysedAgain() throws {
        let archive = SessionArchive(directory: directory)
        let night = recording(from: lastNight, hours: 7, rr: 1000)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let asked = expectation(forNotification: .flowRecoveryRescoreNeeded, object: nil) { notification in
            notification.object as? UUID == night.id && notification.userInfo?["reason"] as? String == NightBeatsEdit.rescoreReason
        }

        let entry = try archive.archive(recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980))

        XCTAssertEqual(entry.sessionId, night.id, "the fixture expects the second recording folded")
        wait(for: [asked], timeout: 2)
    }

    /// An import a batch folds into a night asks the same.
    func testABatchFoldAsksForTheNightToBeAnalysedAgain() throws {
        let archive = SessionArchive(directory: directory)
        let night = recording(from: lastNight, hours: 7, rr: 1000)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let asked = expectation(forNotification: .flowRecoveryRescoreNeeded, object: nil) { notification in
            notification.object as? UUID == night.id
        }

        try archive.store.archiveBatch([recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980)])

        wait(for: [asked], timeout: 2)
    }

    /// A merge that only fills in missing fields leaves the beats alone and
    /// asks for nothing.
    func testAMergeThatAddsNoBeatsDoesNotChangeThem() {
        var existing = MergeClockFixture.session(start: start, minutes: 60, meanRR: 1000)
        var imported = existing
        imported.rrSeries = nil
        imported.notes = "slept late"

        let merge = SessionMerger.mergeSessionDataChangingBeats(from: imported, into: &existing)

        XCTAssertFalse(merge.beatsChanged)
    }

    /// The span is an input of a rescore: a night whose end moved is not
    /// the one a pass read.
    func testARescoreSeesAMovedEnd() {
        let night = MergeClockFixture.session(start: start, minutes: 60, meanRR: 1000)
        var moved = night
        moved.endDate = night.endDate?.addingTimeInterval(-1_800)

        XCTAssertFalse(RescoreWrite.inputsMatch(moved, night, kind: .reanalysis(healedTraining: false)))
        XCTAssertTrue(RescoreWrite.inputsMatch(night, night, kind: .reanalysis(healedTraining: false)))
    }

    /// Undoing a strap merge puts back the beats and everything computed
    /// from them.
    func testUndoingAMergeRestoresTheBeatsAndTheirDerivedFields() {
        let before = pickedNight()
        var stored = before
        NightBeatsEdit.replaceBeats(of: &stored, with: MergeClockFixture.points(minutes: 30, meanRR: 1000))

        SessionRecoveryCoordinator.restoreBeatsAndDerivedFields(of: before, in: &stored)

        XCTAssertEqual(stored.rrSeries?.points.count, before.rrSeries?.points.count)
        XCTAssertEqual(stored.endDate, before.endDate)
        XCTAssertEqual(stored.windowUserAdjusted, true)
        XCTAssertEqual(stored.artifactFlags?.count, before.artifactFlags?.count)
    }
}
