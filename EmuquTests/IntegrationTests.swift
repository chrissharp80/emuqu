@testable import Emuqu
import os
import XCTest

/// Integration tests covering acceptance criteria
final class IntegrationTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        // Pin to UTC so date-bucketing assertions don't shift when run on a
        // machine with a different system time zone (the suite uses
        // hardcoded `Date(timeIntervalSince1970:)` literals).
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Critical: Reconciliation

    /// Reconciliation should block session start if session exists
    func testReconciliationBlocksDuplicateSession() throws {
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconciliationTest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: archiveDirectory) }
        let archive = SessionArchive(directory: archiveDirectory)
        let reconciliation = ReconciliationManager(archive: archive)

        // Create and complete a session
        var session = HRVSession(
            startDate: Date(timeIntervalSince1970: 1_700_100_000),
            sessionType: .quick
        )
        session.endDate = Date()
        session.state = .complete
        session.rrSeries = createTestSeries(beatCount: 150, sessionId: session.id)

        // Archive it
        try archive.archive(session)

        // Reconciliation should now block this session ID
        XCTAssertTrue(
            reconciliation.sessionExists(session.id),
            "Reconciliation should report session exists after archiving"
        )

        // Trying to queue again should throw
        XCTAssertThrowsError(try reconciliation.queueForSync(session)) { error in
            XCTAssertTrue(error is ReconciliationManager.ReconciliationError)
        }
    }

    // MARK: - Archive Integrity

    /// Archive hash should match file bytes
    func testArchiveHashMatchesFileBytes() throws {
        // Hermetic directory, not the shared App Group one. `verifyIntegrity()`
        // walks EVERY entry in the archive, so a single stale index entry left
        // by any other suite in the process fails this test on a session it
        // wrote correctly. See EmuquTests/RRCollectorStateMachineTests.swift.
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveHashTest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: archiveDirectory) }
        let archive = SessionArchive(directory: archiveDirectory)

        var session = HRVSession()
        session.endDate = Date()
        session.state = .complete
        session.rrSeries = createTestSeries(beatCount: 200, sessionId: session.id)

        _ = try archive.archive(session)

        // Verify integrity
        let results = archive.verifyIntegrity()
        XCTAssertTrue(
            results[session.id] == true,
            "Archive integrity check should pass"
        )

        // Retrieve and verify hash
        let retrieved = try archive.retrieve(session.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, session.id)
    }

    // MARK: - Duration Calculation

    /// Duration should use last.endMs
    func testDurationCalculation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 850),
            RRPoint(t_ms: 1650, rr_ms: 750)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        // Duration should be from first t_ms to last endMs
        // last.endMs = 1650 + 750 = 2400
        // first.t_ms = 0
        // duration = 2400 - 0 = 2400ms
        XCTAssertEqual(
            series.durationMs,
            2400,
            "Duration should be last.endMs - first.t_ms"
        )
    }

    // MARK: - Window Selection

    /// Recovery window should be found within temporal constraints
    func testRecoveryWindowSelectionWithTemporalConstraints() {
        let windowSelector = WindowSelector()

        // Create long series (simulating overnight - 8 hours at ~60bpm)
        // Use more realistic variation to produce valid DFA patterns
        let beatCount = 28800 // ~8 hours
        var points: [RRPoint] = []
        var t_ms: Int64 = 0
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0x1D_E5)

        for i in 0 ..< beatCount {
            // More physiological variation pattern
            let baseRR = 1000
            let slowWave = Int(20.0 * sin(Double(i) / 100.0)) // Slow respiratory variation
            let fastWave = Int(10.0 * sin(Double(i) / 10.0)) // Faster variation
            let noise = Int.random(in: -15 ... 15, using: &generator) // Seeded noise
            let rr = baseRR + slowWave + fastWave + noise

            points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
            t_ms += Int64(rr)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Wake time at the end of the recording
        let wakeTimeMs = t_ms

        let window = windowSelector.findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)

        // Should find a window (may be organized or high-variability depending on DFA)
        XCTAssertNotNil(window, "Should find a window for 8-hour recording")

        // Window should be within the temporal representativeness band (30-70%)
        if let window, let relativePosition = window.relativePosition {
            XCTAssertGreaterThanOrEqual(
                relativePosition,
                0.30,
                "Window should be at least 30% into sleep episode"
            )
            XCTAssertLessThanOrEqual(
                relativePosition,
                0.70,
                "Window should be at most 70% into sleep episode"
            )
        }
    }

    /// Test that short sleep returns no representative window
    func testNoRepresentativeWindowForShortSleep() {
        let windowSelector = WindowSelector()

        // Create short series (2 hours at ~60bpm)
        // With 3-hour pre-wake search window, all windows will be outside 30-70% band
        let beatCount = 7200 // ~2 hours
        let points = (0 ..< beatCount).map { i in
            RRPoint(t_ms: Int64(i * 1000), rr_ms: 1000 + (i % 50))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Wake time at the end
        let wakeTimeMs = Int64(beatCount * 1000)

        let window = windowSelector.findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)

        // With a 2-hour recording and 3-hour search window, all windows are in the last portion
        // which falls outside the 30-70% band, so no representative window should be found
        // This is the expected behavior for short/fragmented sleep
        XCTAssertNil(window, "Short sleep should return nil (no representative window)")
    }

    // MARK: - Full Analysis Pipeline

    /// Test complete analysis pipeline
    func testFullAnalysisPipeline() throws {
        // Generate realistic RR data with some variability
        let beatCount = 300 // 5 minutes at ~60bpm
        var points = [RRPoint]()
        var t: Int64 = 0
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0x5EED)

        for _ in 0 ..< beatCount {
            let rr = 1000 + Int.random(in: -100 ... 100, using: &generator) // ~60 bpm, seeded variability
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        // Detect artifacts
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Should have mostly clean data
        let artifactPct = detector.artifactPercentage(flags, start: 0, end: beatCount)
        XCTAssertLessThan(
            artifactPct,
            20,
            "Realistic data should have <20% artifacts"
        )

        // Time domain analysis
        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(timeDomain)
        XCTAssertGreaterThan(try XCTUnwrap(timeDomain?.rmssd), 0)
        XCTAssertGreaterThan(try XCTUnwrap(timeDomain?.sdnn), 0)

        // Frequency domain analysis
        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(frequencyDomain)
        XCTAssertGreaterThan(try XCTUnwrap(frequencyDomain?.totalPower), 0)

        // Nonlinear analysis
        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(nonlinear)
        XCTAssertGreaterThan(try XCTUnwrap(nonlinear?.sd1), 0)
        XCTAssertGreaterThan(try XCTUnwrap(nonlinear?.sd2), 0)
    }

    // MARK: - Helpers

    private func createTestSeries(beatCount: Int, sessionId: UUID) -> RRSeries {
        let points = (0 ..< beatCount).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }
        return RRSeries(points: points, sessionId: sessionId, startDate: Date())
    }

    // MARK: - Sleep Fetch Window

    func testSleepFetchWindowExtendsToMorningCutoffForOvernight() throws {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let mergeGap: TimeInterval = 4.5 * 60 * 60
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let start = try XCTUnwrap(calendar.date(byAdding: .hour, value: 23, to: anchor))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 3, to: anchor))

        let session = makeSession(start: start, end: end, state: .complete, type: .overnight)
        let window = HRVSession.sleepFetchWindow(
            for: session,
            allSessions: [],
            sleepSchedule: schedule,
            mergeGapSeconds: mergeGap
        )

        let cutoff = schedule.morningCutoff(relativeTo: start)
        XCTAssertEqual(window.start, start, "Sleep fetch should keep the recording start")
        XCTAssertEqual(window.end, cutoff, "Sleep fetch should extend to morning cutoff for split-night capture")
        XCTAssertGreaterThan(window.end, end, "Sleep fetch end should include post-recording sleep segments")
    }

    func testSleepFetchWindowUsesChainStartAndExtendsBeyondRecoveryWindow() throws {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let mergeGap: TimeInterval = 4.5 * 60 * 60
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let first = try makeSession(
            start: XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: anchor)),
            end: XCTUnwrap(calendar.date(byAdding: .hour, value: 23, to: anchor)),
            state: .complete,
            type: .overnight
        )
        let target = try makeSession(
            start: XCTUnwrap(calendar.date(byAdding: .hour, value: 23, to: anchor)),
            end: XCTUnwrap(calendar.date(byAdding: .hour, value: 25, to: anchor)),
            state: .complete,
            type: .overnight
        )
        let continuation = try makeSession(
            start: XCTUnwrap(calendar.date(byAdding: .hour, value: 27, to: anchor)),
            end: XCTUnwrap(calendar.date(byAdding: .hour, value: 28, to: anchor)),
            state: .complete,
            type: .overnight
        )

        let recoveryWindow = HRVSession.recoveryPeriodWindow(
            for: target,
            allSessions: [first, continuation],
            sleepSchedule: schedule,
            mergeGapSeconds: mergeGap
        )
        let sleepWindow = HRVSession.sleepFetchWindow(
            for: target,
            allSessions: [first, continuation],
            sleepSchedule: schedule,
            mergeGapSeconds: mergeGap
        )

        XCTAssertEqual(recoveryWindow.start, first.startDate, "Recovery window should chain to earlier segment start")
        XCTAssertEqual(recoveryWindow.end, continuation.endDate, "Recovery window should chain to continuation end")

        let cutoff = schedule.morningCutoff(relativeTo: recoveryWindow.start)
        XCTAssertEqual(sleepWindow.start, recoveryWindow.start, "Sleep fetch should reuse chained start")
        XCTAssertEqual(sleepWindow.end, cutoff, "Sleep fetch should extend chained window to morning cutoff")
        XCTAssertGreaterThan(sleepWindow.end, recoveryWindow.end, "Sleep fetch should extend beyond chained recording end")
    }

    func testSleepFetchWindowDoesNotExtendNonOvernightSessions() throws {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let mergeGap: TimeInterval = 4.5 * 60 * 60
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let start = try XCTUnwrap(calendar.date(byAdding: .hour, value: 14, to: anchor))
        let end = try XCTUnwrap(calendar.date(byAdding: .minute, value: 10, to: start))
        let quick = makeSession(start: start, end: end, state: .complete, type: .quick)

        let window = HRVSession.sleepFetchWindow(
            for: quick,
            allSessions: [],
            sleepSchedule: schedule,
            mergeGapSeconds: mergeGap
        )

        XCTAssertEqual(window.start, start, "Non-overnight fetch should not alter start")
        XCTAssertEqual(window.end, end, "Non-overnight fetch should not extend to morning cutoff")
    }

    func testEffectiveSegmentsKeepValidSplitNight() throws {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let firstStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 23, to: anchor))
        let firstEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 26, to: anchor))
        let secondStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 27, to: anchor))
        let secondEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 30, to: anchor))

        let segments: [HealthKitManager.SleepSegment] = [
            .init(
                sleepStart: firstStart,
                sleepEnd: firstEnd,
                totalSleepMinutes: 180,
                deepSleepMinutes: nil,
                remSleepMinutes: nil,
                coreSleepMinutes: nil,
                awakeMinutes: 0
            ),
            .init(
                sleepStart: secondStart,
                sleepEnd: secondEnd,
                totalSleepMinutes: 180,
                deepSleepMinutes: nil,
                remSleepMinutes: nil,
                coreSleepMinutes: nil,
                awakeMinutes: 0
            )
        ]

        let sleep = SleepData(
            date: secondEnd,
            inBedStart: firstStart,
            sleepStart: firstStart,
            sleepEnd: secondEnd,
            totalSleepMinutes: 360,
            inBedMinutes: 420,
            deepSleepMinutes: nil,
            remSleepMinutes: nil,
            awakeMinutes: 60,
            sleepEfficiency: 85.7,
            boundarySource: .healthKit,
            segments: segments,
            stageIntervals: [],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )

        XCTAssertEqual(sleep.effectiveSegments.count, 2, "Valid same-night split sessions should be preserved")
        XCTAssertEqual(sleep.nightSleepMinutes, 360, "Valid split-session totals should use segment sum")
    }

    func testNormalizedSplitNightSegmentsCollapsesDuplicateCurrentAndTinyArtifacts() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let currentStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day0))
        let currentEnd = try XCTUnwrap(calendar.date(byAdding: .minute, value: 605, to: currentStart)) // 10h 5m

        let duplicate = LinkedSegmentInfo(id: UUID(), startDate: currentStart, endDate: currentEnd)
        let tinyStart = currentEnd.addingTimeInterval(60)
        let tiny = LinkedSegmentInfo(id: UUID(), startDate: tinyStart, endDate: tinyStart.addingTimeInterval(2 * 60))

        let normalized = SessionArchive.normalizedSplitNightSegments(
            currentSessionId: UUID(),
            currentStartDate: currentStart,
            currentEndDate: currentEnd,
            linkedSegments: [duplicate, tiny]
        )

        XCTAssertEqual(normalized.count, 1, "Duplicate full-range and tiny artifact links should collapse to a single meaningful segment")
    }

    func testNormalizedSplitNightSegmentsPreservesRealSplitNight() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let firstStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day0))
        let firstEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 27, to: day0)) // 3:00 AM
        let secondStart = firstEnd.addingTimeInterval(40 * 60) // 3:40 AM
        let secondEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 32, to: day0)) // 8:00 AM

        let linked = LinkedSegmentInfo(id: UUID(), startDate: firstStart, endDate: firstEnd)

        let normalized = SessionArchive.normalizedSplitNightSegments(
            currentSessionId: UUID(),
            currentStartDate: secondStart,
            currentEndDate: secondEnd,
            linkedSegments: [linked]
        )

        XCTAssertEqual(normalized.count, 2, "Meaningful split-night segments should remain visible")
    }

    func testNormalizedSplitNightSegmentsCollapsesHighOverlapLegacyPairs() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let linkedA = try LinkedSegmentInfo(
            id: UUID(),
            startDate: XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day0)),
            endDate: XCTUnwrap(calendar.date(byAdding: .hour, value: 31, to: day0))
        )
        let linkedB = try LinkedSegmentInfo(
            id: UUID(),
            startDate: XCTUnwrap(calendar.date(byAdding: .minute, value: 20, to: linkedA.startDate)),
            endDate: XCTUnwrap(calendar.date(byAdding: .minute, value: 30, to: linkedA.endDate))
        )

        // Force current segment exclusion (<10m) so normalization relies on linked pair handling.
        let currentStart = linkedA.startDate
        let currentEnd = currentStart.addingTimeInterval(5 * 60)

        let normalized = SessionArchive.normalizedSplitNightSegments(
            currentSessionId: UUID(),
            currentStartDate: currentStart,
            currentEndDate: currentEnd,
            linkedSegments: [linkedA, linkedB]
        )

        XCTAssertEqual(normalized.count, 1, "High-overlap legacy duplicate ranges should collapse to one segment")
    }

    private func makeSession(start: Date, end: Date?, state: HRVSession.SessionState, type: SessionType) -> HRVSession {
        HRVSession(
            id: UUID(),
            startDate: start,
            endDate: end,
            state: state,
            sessionType: type,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
    }
}
