@testable import Emuqu
import XCTest

// Writes that land on the archive while another change is in flight: what was
// saved in between must survive, and what was written must be announced.

extension ArchiveIntegrityTests {
    private func night(_ start: Date, minutes: Double) -> HRVSession {
        let session = MergeClockFixture.session(start: start, minutes: minutes, meanRR: 1000, sessionType: .overnight)
        testSessionIds.append(session.id)
        return session
    }

    private func strapSummary(streamed: Int, merged: Int) -> HRVSession.DataSourceSummary {
        HRVSession.DataSourceSummary(
            selectedSource: "composite", streamingBeats: streamed, deviceBeats: merged, totalBeats: merged,
            beatDifferencePercent: nil, reconnectCount: 0, deviceModel: nil
        )
    }

    /// Pulling the strap's recording reads the night, then waits seconds to
    /// minutes on Bluetooth. A note saved during that wait was overwritten by
    /// the copy read before it; now only the beats and their source change.
    func testAnEditSavedDuringTheStrapDownloadSurvivesTheMerge() throws {
        let start = Self.nightAnchoredDate(daysAgo: 20)
        let streamed = night(start, minutes: 60)
        _ = try archive.archive(streamed)
        let read = try XCTUnwrap(archive.retrieve(streamed.id), "what the recovery read before the download")
        try archive.update(streamed.id) { $0.notes = "Slept badly, sore knee" }
        let strap = MergeClockFixture.session(start: start, minutes: 70, meanRR: 1000, sessionType: .overnight)
        let merged = strap.rrSeries?.points ?? []
        let streamedCount = read.rrSeries?.points.count ?? 0

        let written = try SessionRecoveryCoordinator.writeMergedBeats(
            merged, summary: strapSummary(streamed: streamedCount, merged: merged.count),
            into: streamed.id, replacing: streamedCount, in: archive
        )

        XCTAssertNotNil(written)
        let stored = try XCTUnwrap(archive.retrieve(streamed.id))
        XCTAssertEqual(stored.notes, "Slept badly, sore knee", "the note saved during the download was lost")
        XCTAssertEqual(stored.rrSeries?.points.count, merged.count)
        XCTAssertEqual(stored.dataSourceSummary?.selectedSource, "composite")
    }

    /// Another merge landed while this one downloaded: the beats it would
    /// replace are not the ones it merged, so it writes nothing.
    func testAMergeOverBeatsThatChangedMeanwhileWritesNothing() throws {
        let start = Self.nightAnchoredDate(daysAgo: 22)
        let streamed = night(start, minutes: 60)
        _ = try archive.archive(streamed)
        let streamedCount = streamed.rrSeries?.points.count ?? 0
        let other = MergeClockFixture.session(start: start, minutes: 65, meanRR: 1000, sessionType: .overnight)
        try archive.update(streamed.id) { $0.rrSeries = other.rrSeries }
        let mine = MergeClockFixture.session(start: start, minutes: 70, meanRR: 1000, sessionType: .overnight).rrSeries?.points ?? []

        let written = try SessionRecoveryCoordinator.writeMergedBeats(
            mine, summary: strapSummary(streamed: streamedCount, merged: mine.count),
            into: streamed.id, replacing: streamedCount, in: archive
        )

        XCTAssertNil(written)
        XCTAssertEqual(try archive.retrieve(streamed.id)?.rrSeries?.points.count, other.rrSeries?.points.count)
    }

    /// An import that fails on its second session keeps its first one's
    /// change on disk. That change is announced and queued to upload again,
    /// as it would be had the batch finished, and the error still reaches
    /// the caller.
    func testAnImportThatFailsPartwayAnnouncesWhatItWrote() throws {
        let existing = night(Self.nightAnchoredDate(daysAgo: 24), minutes: 60)
        let broken = night(Self.nightAnchoredDate(daysAgo: 26), minutes: 60)
        _ = try archive.archive(existing)
        _ = try archive.archive(broken)
        let brokenPath = try XCTUnwrap(archive.store.entries.first { $0.sessionId == broken.id }?.filePath)
        try FileManager.default.removeItem(at: archive.archiveDirectory.appendingPathComponent(brokenPath))
        var update = night(existing.startDate, minutes: 60)
        update.notes = "Imported note"
        let copyOfBroken = night(broken.startDate, minutes: 60)
        let announced = expectation(forNotification: .flowRecoveryArchiveChanged, object: nil) { note in
            (note.object as? UUID) == existing.id
        }
        let queued = expectation(forNotification: .flowRecoveryArchiveSessionsNeedReupload, object: nil) { note in
            (note.userInfo?["sessionIds"] as? Set<UUID>)?.contains(existing.id) == true
        }

        XCTAssertThrowsError(try archive.store.archiveBatch([update, copyOfBroken]))

        wait(for: [announced, queued], timeout: 2)
        XCTAssertEqual(try archive.retrieve(existing.id)?.notes, "Imported note")
    }

    /// The night is saved before the review card opens, and what the user
    /// does on the card goes to that saved copy. Accepting wrote the card's
    /// older copy back whole; now only the frozen score is written onto the
    /// stored copy, so a note saved during the review stays.
    func testAcceptingANightKeepsWhatWasSavedDuringTheReview() throws {
        let reviewed = night(Self.nightAnchoredDate(daysAgo: 28), minutes: 60)
        _ = try archive.archive(reviewed)
        let read = try XCTUnwrap(archive.retrieve(reviewed.id))
        try archive.update(reviewed.id) { $0.notes = "Felt fine, legs heavy" }
        var frozen = read
        frozen.recoveryScore = 7.4

        let written = try SessionAcceptanceService.writeAccepted(frozen, readFrom: read, to: archive)

        XCTAssertEqual(written?.recoveryScore, 7.4)
        let stored = try XCTUnwrap(archive.retrieve(reviewed.id))
        XCTAssertEqual(stored.notes, "Felt fine, legs heavy", "the note saved on the review card was lost")
        XCTAssertEqual(stored.recoveryScore, 7.4)
    }

    /// A readiness rating given while acceptance fetched from Health changes
    /// what the score is computed from: nothing is written, and acceptance
    /// runs again from the stored copy, rating included.
    func testARatingGivenDuringAcceptanceIsNotScoredOver() throws {
        let reviewed = night(Self.nightAnchoredDate(daysAgo: 30), minutes: 60)
        _ = try archive.archive(reviewed)
        let read = try XCTUnwrap(archive.retrieve(reviewed.id))
        try archive.update(reviewed.id) { $0.perceivedReadiness = 0.8 }
        var frozen = read
        frozen.recoveryScore = 6.1

        XCTAssertNil(try SessionAcceptanceService.writeAccepted(frozen, readFrom: read, to: archive))
        XCTAssertEqual(try archive.retrieve(reviewed.id)?.perceivedReadiness, 0.8)
    }

    /// A night deleted while it was accepted is not written back.
    func testANightDeletedDuringAcceptanceIsNotWrittenBack() throws {
        let reviewed = night(Self.nightAnchoredDate(daysAgo: 32), minutes: 60)
        _ = try archive.archive(reviewed)
        let read = try XCTUnwrap(archive.retrieve(reviewed.id))
        _ = try archive.deleteWithoutTrash(reviewed.id)

        XCTAssertThrowsError(try SessionAcceptanceService.writeAccepted(read, readFrom: read, to: archive))
        XCTAssertFalse(archive.store.exists(reviewed.id))
    }
}
