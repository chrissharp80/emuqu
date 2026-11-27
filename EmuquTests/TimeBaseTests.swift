@testable import Emuqu
import XCTest

/// Every time the app stores or shows is on the clock the event happened on.
/// A streamed beat's `t_ms` sums the intervals received and stands still
/// through a dropout, so a time of night read from it is early by the lost
/// minutes; a Watch control arrives after the tap; a night processed on a
/// later day is not read as of the processing day.
@MainActor
final class TimeBaseTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    /// A streamed night: 10 minutes of beats, a 30-minute dropout (the wall
    /// clock jumps, `t_ms` does not), then 10 more minutes.
    private func streamedNightWithDropout() -> [RRPoint] {
        let before = (0 ..< 600).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000, hr: 60) }
        let after = (600 ..< 1_200).map {
            RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000 + 1_800_000, hr: 60)
        }
        return before + after
    }

    private var series: RRSeries {
        RRSeries(points: streamedNightWithDropout(), sessionId: UUID(), startDate: start)
    }

    /// Where 1,200 one-second beats end: 20 minutes of beats plus the
    /// 30-minute dropout.
    private var realEnd: Date { start.addingTimeInterval(3_000) }

    // MARK: - The end of a recording

    /// Every site that dates a recording's end from its beats reads the real
    /// clock: the same-night merge, the morning's sleep poll, the morning
    /// session, a raw backup, a strap download and the archive's span.
    func testEveryRecordingEndIsOnTheRealClock() {
        let points = streamedNightWithDropout()
        let backup = RawRRBackup.BackupEntry(id: UUID(), captureDate: start, deviceId: nil, points: points, hash: "")
        let ends: [(String, Date?)] = [
            ("lastBeatEnd", points.lastBeatEnd(after: start)),
            ("NightSegment.endDate", MorningProcessingService.NightSegment(startDate: start, points: points).endDate),
            ("backupEndDate", SessionRecoveryService.backupEndDate(backup)),
            ("lastBeatDate", DeviceRecordingSession.lastBeatDate(of: series)),
            ("actualEndDate", series.actualEndDate)
        ]
        for (site, end) in ends {
            XCTAssertEqual(end, realEnd, site)
        }
    }

    /// A strap's own recording has no wall clock and no gaps: its `t_ms` is
    /// the real clock.
    func testAnInternalRecordingEndsAtItsLastBeat() {
        let points = (0 ..< 10).map { RRPoint(t_ms: Int64($0) * 1_000 + 5_000, rr_ms: 1_000) }
        XCTAssertEqual(points.lastBeatEnd(after: start), start.addingTimeInterval(15))
        XCTAssertNil([RRPoint]().lastBeatEnd(after: start))
    }

    /// Two segments of one sleep 20 minutes apart stay one sleep under a
    /// 30-minute merge gap although the first lost 30 minutes to a dropout.
    func testASegmentWithADropoutIsNotSplitFromTheNextOne() {
        let first = MorningProcessingService.NightSegment(startDate: start, points: streamedNightWithDropout())
        let second = MorningProcessingService.NightSegment(
            startDate: realEnd.addingTimeInterval(1_200), points: [RRPoint(t_ms: 0, rr_ms: 1_000, wallClockMs: 0, hr: 60)],
            sessionId: UUID()
        )
        XCTAssertEqual(MorningProcessingService.segmentsWithinGap([first, second], gap: 1_800).count, 2)
    }

    // MARK: - Times of night shown from the beats

    /// A position after the dropout reads 30 minutes later than `t_ms` says;
    /// past either end the time runs on from that end.
    func testATMsPositionReadsTheRealClock() {
        let series = series
        XCTAssertEqual(series.clockTime(forTMs: 300_000), start.addingTimeInterval(300))
        XCTAssertEqual(series.clockTime(forTMs: 900_000), start.addingTimeInterval(2_700))
        XCTAssertEqual(series.clockTime(forTMs: 1_259_000), start.addingTimeInterval(3_059))
        XCTAssertEqual(series.clockSpanMs, 2_999_000)
    }

    /// The recovery-score charts and engine room draw and label every mark on
    /// that clock: the RMSSD and heart-rate traces, the window, the nadir.
    func testTheRecoveryChartsPlaceTheirMarksOnTheRealClock() throws {
        let series = series
        let hr = RecoveryScoreCharts.buildHRSeries(series: series, flags: nil, fallbackHRSamples: [])
        let afterGap = try XCTUnwrap(hr.first { $0.time > start.addingTimeInterval(600) })
        XCTAssertGreaterThanOrEqual(afterGap.time, start.addingTimeInterval(2_400))
        let rmssd = RecoveryScoreCharts.buildRMSSDSeries(series: series, flags: nil)
        XCTAssertEqual(rmssd.last?.time, start.addingTimeInterval(2_640), "the window starting at t_ms 840 s")
        let session = HRVSession(startDate: start, sessionType: .overnight)
        XCTAssertEqual(session.clockTime(forTMs: 900_000, series: series), start.addingTimeInterval(2_700))
        XCTAssertEqual(session.clockTime(forTMs: 900_000, series: nil), start.addingTimeInterval(900))
    }

    /// A window after the dropout is labelled with the sleep segment it is
    /// in on the session clock, not with an earlier one.
    func testAWindowIsMatchedToItsSegmentOnTheSessionClock() {
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.rrSeries = series
        XCTAssertEqual(ReanalysisService.sessionClockMs(ofTMs: 900_000, in: session), 2_700_000)
        session.rrSeries = nil
        XCTAssertEqual(ReanalysisService.sessionClockMs(ofTMs: 900_000, in: session), 900_000)
    }

    /// A streamed night that lost an hour of packets two hours into sleep:
    /// the stages run to the night's real wake, not an hour short of it, as
    /// the classifier places its windows on the wall clock.
    func testHREstimatedStagesRunToTheRealWake() throws {
        var points: [RRPoint] = []
        var t: Int64 = 0
        var lostMs: Int64 = 0
        for i in 0 ..< 21_000 {
            let rr = i < 1_080 ? 833 : (i.isMultiple(of: 2) ? 1_080 : 1_100)
            if i == 1_080 + 6_600 { lostMs = 3_600_000 }
            points.append(RRPoint(t_ms: t, rr_ms: rr, wallClockMs: t + lostMs, hr: nil))
            t += Int64(rr)
        }
        let result = try XCTUnwrap(HRSleepEstimator.estimateSleepFromHR(rrPoints: points, recordingStart: start))
        let sleepEnd = try XCTUnwrap(result.sleepEnd)
        let lastStageEnd = try XCTUnwrap(result.stageIntervals.map(\.end).max())
        XCTAssertGreaterThan(lastStageEnd, sleepEnd.addingTimeInterval(-600))
    }

    /// A Verity Sense night saved as two offline recordings an hour apart:
    /// the second keeps its time of night instead of following straight on
    /// from the first, and neither clock runs back when its stamp reads early.
    func testASecondOfflineRecordingKeepsItsTimeOfNight() {
        let earlier = (0 ..< 600).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000) }
        let later = (0 ..< 10).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000) }
        let offset = { (start: Date) in
            StrapRecordingCoordinator.continuedOffsetMs(later, startedAt: start, after: earlier, firstStart: self.start)
        }
        XCTAssertEqual(offset(start.addingTimeInterval(4_200)), 4_200_000)
        XCTAssertEqual(offset(start.addingTimeInterval(60)), 600_000)
        XCTAssertEqual(StrapRecordingCoordinator.continuedOffsetMs(later, startedAt: start, after: [], firstStart: start), 0)
    }

    // MARK: - A workout's beats against its other clocks

    /// The strap links 20 s after the workout began: its first beat is
    /// placed at 20 s, not at the start, so heart rate lines up with the GPS
    /// and the samples, and the live clock agrees.
    func testAWorkoutsBeatsCountFromTheStreamStart() {
        let points = (0 ..< 5).map { RRPoint(t_ms: Int64($0) * 500, rr_ms: 500, wallClockMs: 20_000 + Int64($0) * 500, hr: 120) }
        XCTAssertEqual(WorkoutAnalyzer.gapCorrectedOffsetsMs(points), [20_000, 20_500, 21_000, 21_500, 22_000])
        var clock = LiveDFAAnalyzer.BeatClock()
        XCTAssertEqual(points.map { clock.stamp($0).t_ms }, WorkoutAnalyzer.gapCorrectedOffsetsMs(points))
        let cut = WorkoutAnalyzer.rrPoints(points, endingAt: start.addingTimeInterval(21), sessionStart: start)
        XCTAssertEqual(cut.count, 3)
    }

    // MARK: - Watch controls

    /// A Watch Pause starts at the tap, held after the last resume and not
    /// after now.
    func testAWatchPauseIsDatedByTheTap() {
        let now = start.addingTimeInterval(600)
        let resumed = start.addingTimeInterval(300)
        XCTAssertEqual(WorkoutRecorder.pauseDate(requested: nil, since: resumed, now: now), now)
        XCTAssertEqual(WorkoutRecorder.pauseDate(requested: now.addingTimeInterval(-40), since: resumed, now: now), now.addingTimeInterval(-40))
        XCTAssertEqual(WorkoutRecorder.pauseDate(requested: start, since: resumed, now: now), resumed)
        XCTAssertEqual(WorkoutRecorder.pauseDate(requested: now.addingTimeInterval(5), since: resumed, now: now), now)
    }

    /// The pause moved back to the tap counts from there: active time stops
    /// at the tap, and its backup row says so.
    func testAMovedPauseCountsFromTheTap() {
        var timeline = PauseTimeline()
        let applied = start.addingTimeInterval(600)
        timeline.pause(atElapsed: 600, now: applied)
        timeline.movePauseStart(to: start.addingTimeInterval(560), atElapsed: 560)
        XCTAssertEqual(timeline.activeSeconds(sessionStart: start, now: applied), 560)
        XCTAssertEqual(timeline.events.map(\.pausedAt), [start.addingTimeInterval(560)])
        timeline.resume(now: start.addingTimeInterval(900))
        XCTAssertEqual(timeline.spans.map(\.seconds), [340])
    }

    /// A Watch Pause tapped 40 s before it arrived: the workout pauses at the
    /// tap and the samples the phone took after it are not the workout's.
    func testAWatchPauseThatArrivedLateLeavesOutWhatFollowedTheTap() {
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        let now = Date()
        let started = now.addingTimeInterval(-600)
        recorder.lifecycle.sessionStartDate = started
        recorder.lifecycle.elapsedSeconds = 600
        recorder.capture.workoutSamples = (1 ... 600).map { WorkoutSample(offsetSec: $0, heartRate: 140, distanceMeters: Double($0) * 3, powerWatts: 200) }
        recorder.lifecycle.phase = .recording

        recorder.pauseFromWatch(tappedAt: now.addingTimeInterval(-40), now: now)

        XCTAssertTrue(recorder.lifecycle.isPaused)
        XCTAssertEqual(recorder.lifecycle.elapsedSeconds, 560)
        XCTAssertEqual(recorder.capture.workoutSamples.last?.offsetSec, 560)
        XCTAssertEqual(recorder.lifecycle.pauseTimeline.events.last?.pausedAt, now.addingTimeInterval(-40))
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TimeBaseTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - A night processed later

    /// An interrupted recording recovered at a relaunch hours later is
    /// paused where its beats ran out, not at the relaunch.
    func testAnInterruptedRecordingIsPausedWhereItsBeatsRanOut() {
        let relaunch = realEnd.addingTimeInterval(4 * 3_600)
        XCTAssertEqual(SessionRecoveryService.interruptedPauseDate(lastBeatEnd: realEnd, now: relaunch), realEnd)
        XCTAssertEqual(SessionRecoveryService.interruptedPauseDate(lastBeatEnd: nil, now: relaunch), relaunch)
        XCTAssertEqual(SessionRecoveryService.interruptedPauseDate(lastBeatEnd: relaunch.addingTimeInterval(60), now: relaunch), relaunch)
    }

    /// A night's training load is read as of its own end, never later than
    /// now: one rebuilt days later is not scored against the processing
    /// day's load.
    func testANightsTrainingLoadIsReadAsOfItsEnd() {
        let now = start.addingTimeInterval(3 * 86_400)
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.endDate = start.addingTimeInterval(8 * 3_600)
        XCTAssertEqual(MorningSessionPipeline.trainingAsOf(session, now: now), start.addingTimeInterval(8 * 3_600))
        session.endDate = nil
        XCTAssertEqual(MorningSessionPipeline.trainingAsOf(session, now: now), now)
        session.endDate = now.addingTimeInterval(60)
        XCTAssertEqual(MorningSessionPipeline.trainingAsOf(session, now: now), now)
    }

    // MARK: - A Watch control that arrives after the phone moved on

    /// A control applies only when it was tapped at or after the last change
    /// it would act on; one with no tap time, or no change before it, applies.
    func testAWatchControlAppliesOnlyWhenTappedAfterTheLastChange() {
        let change = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(tap: Date?, last: Date?, applies: Bool)] = [
            (change.addingTimeInterval(-1), change, false), (change, change, true),
            (change.addingTimeInterval(1), change, true), (nil, change, true), (change, nil, true)
        ]
        for testCase in cases {
            XCTAssertEqual(WorkoutRecorder.controlIsCurrent(tappedAt: testCase.tap, lastChange: testCase.last), testCase.applies, "\(String(describing: testCase))")
        }
    }

    /// A Watch Pause tapped before the user resumed on the phone was answered
    /// by that resume: delivered late, it does not pause the workout again.
    func testAWatchPauseTappedBeforeThePhoneResumedIsIgnored() {
        let recorder = recordingWorkout(startedAgo: 600)
        let now = Date()
        recorder.pauseControl.pause()
        recorder.pauseControl.resume(at: now.addingTimeInterval(-60))

        recorder.pauseFromWatch(tappedAt: now.addingTimeInterval(-90), now: now)
        XCTAssertFalse(recorder.lifecycle.isPaused, "a stale Watch Pause paused the workout again")

        recorder.pauseFromWatch(tappedAt: now.addingTimeInterval(-30), now: now)
        XCTAssertTrue(recorder.lifecycle.isPaused, "a Watch Pause tapped after the resume applies")
    }

    /// A Watch Resume tapped before the pause now open began does not end it.
    func testAWatchResumeTappedBeforeTheOpenPauseIsIgnored() {
        let recorder = recordingWorkout(startedAgo: 600)
        let now = Date()
        recorder.pauseControl.pause()
        recorder.lifecycle.pauseTimeline.movePauseStart(to: now.addingTimeInterval(-60), atElapsed: 540)

        recorder.resumeFromWatch(tappedAt: now.addingTimeInterval(-90), now: now)
        XCTAssertTrue(recorder.lifecycle.isPaused, "a stale Watch Resume ended a newer pause")

        recorder.resumeFromWatch(tappedAt: now.addingTimeInterval(-30), now: now)
        XCTAssertFalse(recorder.lifecycle.isPaused)
    }

    /// A Watch Done tapped before the workout now finished ended was meant
    /// for an earlier summary and leaves this one.
    func testAWatchDoneTappedBeforeThisWorkoutEndedIsIgnored() {
        let recorder = recordingWorkout(startedAgo: 600)
        let now = Date()
        var finished = HRVSession(startDate: now.addingTimeInterval(-600), sessionType: .workout)
        finished.endDate = now.addingTimeInterval(-60)
        recorder.lifecycle.finishedSession = finished
        recorder.lifecycle.phase = .finished

        recorder.acknowledgeFinishedFromWatch(tappedAt: now.addingTimeInterval(-90))
        XCTAssertEqual(recorder.lifecycle.phase, .finished, "a stale Watch Done dismissed this workout's summary")

        recorder.acknowledgeFinishedFromWatch(tappedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(recorder.lifecycle.phase, .idle)
    }

    private func recordingWorkout(startedAgo seconds: TimeInterval) -> WorkoutRecorder {
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        recorder.lifecycle.sessionStartDate = Date().addingTimeInterval(-seconds)
        recorder.lifecycle.elapsedSeconds = Int(seconds)
        recorder.lifecycle.phase = .recording
        return recorder
    }
}
