@testable import Emuqu
import XCTest

/// An automatic path (a sleep refresh, a sleep update from Apple Health, a
/// merge, an iCloud pull, a rebuild, a launch migration) never replaces,
/// clears or drops what the user set on a session: a sleep they adjusted,
/// their tags, notes and answers.
final class UserChoicesKeptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UserChoicesKeptTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(
        directory: directory,
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .off }
    )

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func night() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    private func sleep(startMin: Int, minutes: Int) -> SleepData {
        let sleepStart = start.addingTimeInterval(Double(startMin) * 60)
        return SleepData(
            date: sleepStart, sleepStart: sleepStart, sleepEnd: sleepStart.addingTimeInterval(Double(minutes) * 60),
            totalSleepMinutes: minutes, inBedMinutes: minutes, awakeMinutes: 0,
            sleepEfficiency: 95, boundarySource: .healthKit
        )
    }

    /// A night whose sleep the user set from 00:30 for five hours.
    private func adjustedNight(withSnapshot: Bool) -> HRVSession {
        var adjusted = night()
        adjusted.sleepStartMs = 1_800_000
        adjusted.sleepEndMs = 19_800_000
        adjusted.sleepUserAdjusted = true
        adjusted.sleepSnapshot = withSnapshot ? sleep(startMin: 30, minutes: 300) : nil
        return adjusted
    }

    // MARK: - Sleep refresh and sleep updates

    /// The automatic refresh read the night before the user saved a sleep
    /// edit, and Health answered after: the write, on the copy stored then,
    /// leaves the edit.
    func testAnAutomaticRefreshLeavesASleepTheUserEditedWhileHealthWasRead() throws {
        let edited = adjustedNight(withSnapshot: true)
        try archive.archive(edited, skipSameNightMerge: true)

        let written = try archive.updateIfChanged(edited.id, requestingReupload: false) {
            SleepRefreshPolicy.applyAutoRefreshIfAllowed(self.sleep(startMin: 5, minutes: 420), to: &$0)
        }

        XCTAssertFalse(written)
        let stored = try XCTUnwrap(archive.retrieve(edited.id))
        XCTAssertEqual(stored.sleepSnapshot?.nightSleepMinutes, 300, "Health's sleep replaced the user's")
        XCTAssertEqual(stored.sleepStartMs, 1_800_000)
    }

    /// An automatic sleep update of a night whose adjusted sleep came without
    /// its snapshot fills the snapshot and keeps the boundaries the user set,
    /// and its score.
    func testAnAutomaticSleepUpdateKeepsTheBoundariesTheUserSet() throws {
        var adjusted = adjustedNight(withSnapshot: false)
        adjusted.recoveryScore = 7.1
        let edit = try XCTUnwrap(SleepBoundaryWrite.Edit(sleepData: sleep(startMin: 5, minutes: 420), isUserAdjustment: false))
        let context = RescoreContext(
            baselineStats: nil, typicalSleepHours: 8,
            scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
                enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
            )
        )

        SleepBoundaryWrite.apply(edit, to: &adjusted, inputs: SleepBoundaryWrite.Inputs(context: context, fallbackTraining: nil))

        XCTAssertEqual(adjusted.sleepStartMs, 1_800_000, "Health's start replaced the one the user set")
        XCTAssertEqual(adjusted.sleepEndMs, 19_800_000)
        XCTAssertEqual(adjusted.sleepUserAdjusted, true)
        XCTAssertEqual(adjusted.sleepSnapshot?.nightSleepMinutes, 420, "the missing snapshot was not filled")
        XCTAssertEqual(adjusted.recoveryScore, 7.1)
    }

    // MARK: - Merges, pulls and rebuilds

    /// A streamed copy and the strap's file of the same recording: whichever
    /// side's sleep the user adjusted is the merged night's sleep, not the
    /// strap file's bounds or the other side's snapshot.
    func testAMergeKeepsTheSleepTheUserAdjustedOnEitherSide() {
        for userAdjustedStream in [true, false] {
            let points = MergeClockFixture.points(minutes: 60, meanRR: 1000)
            var stream = MergeClockFixture.session(start: start, points: points, source: "streaming")
            var strap = MergeClockFixture.session(start: start, points: points, source: "internal")
            (stream.sleepStartMs, stream.sleepEndMs, stream.sleepSnapshot) = (600_000, 3_000_000, sleep(startMin: 10, minutes: 40))
            (strap.sleepStartMs, strap.sleepEndMs, strap.sleepSnapshot) = (120_000, 3_500_000, sleep(startMin: 2, minutes: 56))
            if userAdjustedStream { stream.sleepUserAdjusted = true } else { strap.sleepUserAdjusted = true }
            let adjusted = userAdjustedStream ? stream : strap

            _ = SessionMerger.mergeSessionData(from: strap, into: &stream)

            XCTAssertEqual(stream.sleepStartMs, adjusted.sleepStartMs, "adjusted stream: \(userAdjustedStream)")
            XCTAssertEqual(stream.sleepEndMs, adjusted.sleepEndMs, "adjusted stream: \(userAdjustedStream)")
            XCTAssertEqual(stream.sleepSnapshot?.nightSleepMinutes, adjusted.sleepSnapshot?.nightSleepMinutes)
            XCTAssertEqual(stream.sleepUserAdjusted, true, "adjusted stream: \(userAdjustedStream)")
        }
    }

    /// A newer iCloud copy written by a build that still sent sleep carries a
    /// window the user never adjusted: the sleep adjusted here stays, the
    /// copy's other edits are taken.
    func testAPulledCopyDoesNotReplaceASleepAdjustedHere() {
        let local = adjustedNight(withSnapshot: true)
        var remote = local
        (remote.sleepStartMs, remote.sleepEndMs, remote.sleepUserAdjusted) = (300_000, 25_000_000, nil)
        remote.sleepSnapshot = sleep(startMin: 5, minutes: 410)
        remote.tags = [ReadingTag.alcohol]

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.sleepStartMs, 1_800_000, "the pulled window replaced the user's sleep")
        XCTAssertEqual(merged.sleepEndMs, 19_800_000)
        XCTAssertEqual(merged.sleepUserAdjusted, true)
        XCTAssertEqual(merged.sleepSnapshot?.nightSleepMinutes, 300)
        XCTAssertEqual(merged.tags, [ReadingTag.alcohol])
    }

    /// A night rebuilt from its recording under the id the archive holds
    /// (a repair, a recovery, a night processed again) keeps the tags, notes,
    /// answers, adjusted sleep and edit stamp of the stored copy, wherever
    /// the rebuild's clock starts.
    func testARebuiltNightKeepsWhatTheUserSetOnTheStoredCopy() throws {
        var stored = adjustedNight(withSnapshot: true)
        stored.tags = [ReadingTag.alcohol]
        stored.notes = "late dinner"
        stored.morningFeeling = 2
        stored.morningFeelingTags = [.infection]
        stored.perceivedReadiness = 0.3
        stored.modifiedAt = Date(timeIntervalSince1970: 1_790_030_000)
        try archive.archive(stored, skipSameNightMerge: true)
        let rebuilt = HRVSession(
            id: stored.id, startDate: start.addingTimeInterval(-600), endDate: stored.endDate,
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )

        let written = try XCTUnwrap(archive.rewriteKeepingUserEdits(rebuilt))

        XCTAssertEqual(written.tags, [ReadingTag.alcohol])
        XCTAssertEqual(written.notes, "late dinner")
        XCTAssertEqual(written.morningFeeling, 2)
        XCTAssertEqual(written.morningFeelingTags, [.infection])
        XCTAssertEqual(written.perceivedReadiness, 0.3)
        XCTAssertEqual(written.modifiedAt, stored.modifiedAt)
        XCTAssertEqual(written.sleepUserAdjusted, true)
        XCTAssertEqual(written.sleepStartMs, 2_400_000, "the sleep is re-counted from the rebuild's start")
        XCTAssertEqual(try archive.retrieve(stored.id)?.notes, "late dinner")
    }

    /// A rebuild of a night the archive does not hold writes nothing.
    func testARebuildOfANightNotArchivedWritesNothing() throws {
        XCTAssertNil(try archive.rewriteKeepingUserEdits(night()))
    }

    // MARK: - Acceptance and launch migrations

    /// The auto-accept's pre-night notes join the notes the night already has
    /// (one it was folded into) instead of replacing them.
    func testPreNightNotesJoinTheNotesTheNightHas() {
        let read = night()
        var updated = read
        updated.notes = "travel day"
        var archived = read
        archived.notes = "first part: woke at 2"

        SessionAcceptanceService.applyUpdate(updated, scoredFrom: read, to: &archived)

        XCTAssertEqual(archived.notes, "first part: woke at 2\n\ntravel day")
    }

    /// The one-time insufficient-data rescore decided on the night as it
    /// read it; a window the user picked since is not flagged and rescored
    /// on that verdict.
    @MainActor
    func testTheInsufficientDataMigrationLeavesANightChangedSinceItsRead() throws {
        var read = MergeClockFixture.session(start: start, minutes: 30, meanRR: 1000, withAnalysis: true)
        read.recoveryScore = 6
        var stored = read
        stored.windowUserAdjusted = true
        stored.analysisResult?.windowStartMs = 123_000
        let context = RescoreContext(
            baselineStats: nil, typicalSleepHours: 8,
            scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
                enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
            )
        )

        XCTAssertFalse(SessionDataMigrations.flagInsufficient(&stored, decidedOn: read, context: context))
        XCTAssertNil(stored.hrvDataQuality, "the picked window was flagged on the old window's verdict")
        XCTAssertEqual(stored.recoveryScore, 6)
        var unchanged = read
        XCTAssertTrue(SessionDataMigrations.flagInsufficient(&unchanged, decidedOn: read, context: context))
        XCTAssertEqual(unchanged.hrvDataQuality, .insufficient)
    }
}
