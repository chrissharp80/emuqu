@testable import Emuqu
import XCTest

// The archive's merge decisions under the user's merge gap: which recordings
// of one night fold together, and which stay separate sleeps. The archive
// fixture injects the default 4.5 h gap.

extension ArchiveIntegrityTests {
    private func overnightEntries(anchoredAt start: Date) -> [SessionArchiveEntry] {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let night = schedule.overnightWindowStart(relativeTo: start)
        return archive.entries.filter {
            $0.sessionType == .overnight && schedule.overnightWindowStart(relativeTo: $0.date) == night
        }
    }

    private func recording(_ start: Date, minutes: Double, meanRR: Int, type: SessionType = .overnight) -> HRVSession {
        let session = MergeClockFixture.session(start: start, minutes: minutes, meanRR: meanRR, sessionType: type)
        testSessionIds.append(session.id)
        return session
    }

    /// The reviewer's night: 23:00 for 90 min, then 05:10 for 120 min. The
    /// 4 h 40 min between them is more than the merge gap, so the morning code
    /// treats them as two sleeps — and so must the archive. Each recording
    /// keeps its own id, start and beats.
    func testRecordingsFurtherApartThanTheMergeGapStaySeparate() throws {
        let start = Self.nightAnchoredDate(daysAgo: 13)
        let early = recording(start, minutes: 90, meanRR: 1000)
        let late = recording(start.addingTimeInterval((6 * 60 + 10) * 60), minutes: 120, meanRR: 850)

        _ = try archive.archive(early)
        _ = try archive.archive(late)

        XCTAssertEqual(overnightEntries(anchoredAt: start).count, 2, "two sleeps, two entries")
        let storedEarly = try XCTUnwrap(archive.retrieve(early.id))
        XCTAssertEqual(storedEarly.rrSeries?.points.count, early.rrSeries?.points.count, "the first sleep is untouched")
        let storedLate = try XCTUnwrap(archive.retrieve(late.id))
        XCTAssertEqual(storedLate.startDate, late.startDate)
    }

    /// 23:00 for 90 min and 04:50 for 120 min: 4 h 20 min apart, one sleep.
    /// The archive merges them on one clock.
    func testRecordingsWithinTheMergeGapMergeOnOneClock() throws {
        let start = Self.nightAnchoredDate(daysAgo: 14)
        let early = recording(start, minutes: 90, meanRR: 1000)
        let late = recording(start.addingTimeInterval((5 * 60 + 50) * 60), minutes: 120, meanRR: 850)

        _ = try archive.archive(early)
        _ = try archive.archive(late)

        XCTAssertEqual(overnightEntries(anchoredAt: start).count, 1)
        let merged = try XCTUnwrap(archive.retrieve(early.id))
        let points = merged.rrSeries?.points ?? []
        XCTAssertEqual(points.count, (early.rrSeries?.points.count ?? 0) + (late.rrSeries?.points.count ?? 0))
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(points), 0)
        XCTAssertLessThan(MergeClockFixture.rmssd(points), 30, "interleaved, this read ~135 ms")
        // The archive encodes dates as ISO 8601, whole seconds; the fixture's
        // end carries a fraction of a second from its beat sums.
        XCTAssertEqual(
            try XCTUnwrap(merged.endDate).timeIntervalSince1970,
            try XCTUnwrap(late.endDate).timeIntervalSince1970, accuracy: 1
        )
    }

    /// Batch import follows the same rule: a same-sleep overnight within the
    /// gap is merged on one clock, not written beside it or laid over it.
    func testBatchImportMergesASameSleepRecordingOnOneClock() throws {
        let start = Self.nightAnchoredDate(daysAgo: 15)
        let early = recording(start, minutes: 90, meanRR: 1000)
        let late = recording(start.addingTimeInterval((5 * 60 + 50) * 60), minutes: 120, meanRR: 850)
        _ = try archive.archive(early)

        XCTAssertEqual(try archive.archiveBatch([late]), 1)

        XCTAssertEqual(overnightEntries(anchoredAt: start).count, 1)
        let points = try XCTUnwrap(archive.retrieve(early.id)?.rrSeries?.points)
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(points), 0)
    }

    /// Two five-minute quick readings 40 minutes apart are two readings. The
    /// old one-hour window folded the second into the first's beats.
    func testBatchImportKeepsTwoReadingsThatDoNotOverlap() throws {
        let start = Self.nightAnchoredDate(daysAgo: 16).addingTimeInterval(-12 * 3600)
        let first = recording(start, minutes: 5, meanRR: 900, type: .quick)
        let second = recording(start.addingTimeInterval(40 * 60), minutes: 5, meanRR: 900, type: .quick)

        XCTAssertEqual(try archive.archiveBatch([first, second]), 2)

        XCTAssertNotNil(try archive.retrieve(first.id))
        XCTAssertNotNil(try archive.retrieve(second.id))
    }

    /// The relink migration links a night's recordings only within the merge
    /// gap: two sleeps of one night anchor stay unlinked; two segments of one
    /// sleep are linked.
    func testRelinkHonoursTheMergeGap() throws {
        let start = Self.nightAnchoredDate(daysAgo: 17)
        let early = recording(start, minutes: 90, meanRR: 1000)
        let late = recording(start.addingTimeInterval((6 * 60 + 10) * 60), minutes: 120, meanRR: 850)
        let nextStart = Self.nightAnchoredDate(daysAgo: 18)
        let first = recording(nextStart, minutes: 90, meanRR: 1000)
        let second = recording(nextStart.addingTimeInterval((5 * 60 + 50) * 60), minutes: 120, meanRR: 850)
        for session in [early, late, first, second] {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }

        archive.relinkSameNightSessions()

        XCTAssertNil(try archive.retrieve(late.id)?.linkedSessionIds, "two sleeps are not one night's segments")
        XCTAssertNil(try archive.retrieve(early.id)?.linkedSessionIds)
        XCTAssertEqual(try archive.retrieve(second.id)?.linkedSessionIds, [first.id])
    }
}
