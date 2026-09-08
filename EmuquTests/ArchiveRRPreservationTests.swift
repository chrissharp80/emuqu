@testable import Emuqu
import XCTest

/// Re-archiving a session must never destroy its beat data, and must never
/// claim it destroyed beat data that was never there.
///
/// `_archive` splices the stored `rrSeries` back into any session arriving
/// without one, because a metadata edit — a note, a morning feeling, a
/// re-smoothed elevation, a CloudKit pull — carries only the fields it
/// touched. The splice has to tell three outcomes apart, and until now it told
/// two: it reported a session that simply has no beats as a file "unreadable by
/// hash-checked AND raw readers … already unrecoverable on disk".
@MainActor
final class ArchiveRRPreservationTests: XCTestCase {
    private lazy var archive = SessionArchive(
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .defaultGap }
    )
    private var written: [UUID] = []

    override func tearDown() async throws {
        await MainActor.run {
            for id in written { try? archive.delete(id) }
            written = []
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func beats(count: Int = 50) -> RRSeries {
        var points: [RRPoint] = []
        var elapsed: Int64 = 0
        for index in 0 ..< count {
            let rr = 800 + ((index % 5) - 2) * 10
            points.append(RRPoint(t_ms: elapsed, rr_ms: rr))
            elapsed += Int64(rr)
        }
        return RRSeries(points: points, sessionId: UUID(), startDate: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A workout with no beat data — a strapless recording, a GPX or Apple
    /// Health import, or a recording that died before its first beat.
    private func beatlessWorkout() -> HRVSession {
        var session = HRVSession(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            tags: [],
            sessionType: .workout
        )
        session.endDate = session.startDate.addingTimeInterval(600)
        session.state = .complete
        session.workoutMetadata = WorkoutMetadata(sport: .walk)
        written.append(session.id)
        return session
    }

    // MARK: - The three-way classification

    /// The regression, asserted where it actually lives.
    ///
    /// A beatless workout reads back perfectly well; there is simply nothing to
    /// preserve. The version of this code that had two outcomes instead of
    /// three called that an unreadable file and reported data loss — for every
    /// strapless workout, every import, and every recording that died before
    /// its first beat.
    ///
    /// Asserted against the classification rather than against the error log:
    /// the catalog is appended asynchronously, so a synchronous check of it
    /// right after archiving passes whether or not anything was ever logged.
    /// The first version of this test did exactly that and asserted nothing at
    /// all; a planted mutation is what said so.
    func testABeatlessSessionClassifiesAsNoBeatsNotAsUnreadable() throws {
        let session = beatlessWorkout()
        _ = try archive.archive(session)

        switch archive.store.storedRRSeries(for: session.id) {
        case .noBeatsStored: break
        case .preserved: XCTFail("there were no beats to preserve")
        case .unreadable: XCTFail("a file that reads back fine is not an unreadable file")
        }
    }

    func testAStoredSessionWithBeatsClassifiesAsPreserved() throws {
        var session = beatlessWorkout()
        session.rrSeries = beats()
        _ = try archive.archive(session)

        switch archive.store.storedRRSeries(for: session.id) {
        case .preserved(let stored, let viaRawDecode):
            XCTAssertEqual(stored.points.count, 50)
            XCTAssertFalse(viaRawDecode, "the hash-checked read should have succeeded")
        case .noBeatsStored, .unreadable:
            XCTFail("stored beats were not found")
        }
    }

    /// A session the archive has no file for is the real failure — the only one
    /// of the three worth telling the user about.
    func testAnUnknownSessionClassifiesAsUnreadable() {
        switch archive.store.storedRRSeries(for: UUID()) {
        case .unreadable: break
        case .preserved, .noBeatsStored: XCTFail("there is no file to read")
        }
    }

    // MARK: - The behaviour the splice exists for

    func testABeatlessWorkoutStaysBeatlessRatherThanGainingData() throws {
        var session = beatlessWorkout()
        _ = try archive.archive(session)
        session.notes = "edited"
        _ = try archive.archive(session)

        XCTAssertNil(try archive.retrieve(session.id)?.rrSeries)
    }

    /// The whole reason the splice exists: a metadata edit arrives carrying no
    /// beats, and must not overwrite the night's recording with nothing.
    func testReArchivingWithoutBeatsPreservesTheStoredOnes() throws {
        var session = beatlessWorkout()
        session.rrSeries = beats()
        _ = try archive.archive(session)

        var metadataOnly = session
        metadataOnly.rrSeries = nil
        metadataOnly.notes = "edited"
        _ = try archive.archive(metadataOnly)

        let stored = try archive.retrieve(session.id)
        XCTAssertEqual(stored?.rrSeries?.points.count, 50)
        XCTAssertEqual(stored?.notes, "edited")
    }
}
