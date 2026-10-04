@testable import Emuqu
import os
import XCTest

/// Tests for MorningProcessingService.
/// Validates overnight processing, series merging, composite point creation,
/// and recovery score computation using real analysis components.
@MainActor
final class MorningProcessingServiceTests: XCTestCase {
    // Built as stored properties rather than implicitly-unwrapped optionals
    // assigned in `setUp`. XCTest instantiates the test class once per test
    // method, so an inline initialiser already gives every test a fresh graph.
    //
    // The two composed dependencies are `lazy` because they read the others,
    // and a stored property cannot reference its siblings during init.
    /// A private archive per test: the processing pass archives nothing
    /// itself, but the merge test seeds one, and a seeded session left in the
    /// shared archive is read by every suite that opens it afterwards.
    private let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MorningProcessingServiceTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: archiveDirectory)
    private var healthKit = MockHealthKitService()
    private var windowSelector = WindowSelector()
    private var artifactDetector = ArtifactDetector()
    private var verification = Verification()
    private var baselineTracker = BaselineTracker()
    private var rawBackup = RawRRBackup()

    private lazy var analysisPipeline = HRVAnalysisPipeline(
        artifactDetector: artifactDetector,
        windowSelector: windowSelector,
        healthKit: healthKit
    )

    private lazy var service = MorningProcessingService(
        archive: archive,
        healthKit: healthKit,
        analysisPipeline: analysisPipeline,
        windowSelector: windowSelector,
        artifactDetector: artifactDetector,
        verification: verification,
        baselineTracker: baselineTracker,
        rawBackup: rawBackup
    )

    private let fixedSessionStart = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01T00:00:00Z

    /// Ids of every session a test handed to the service. Step 1 of the pass
    /// writes the beats to the raw-RR backup store, which has no private
    /// directory, so teardown discards exactly those backups.
    private var processedSessionIds: [UUID] = []

    /// Night assignment reads `Calendar.current`; UTC makes "same night"
    /// mean the same thing on every host. Captured and restored, not leaked.
    nonisolated private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    override func tearDown() async throws {
        for id in processedSessionIds {
            try rawBackup.discardBackup(id)
        }
        if FileManager.default.fileExists(atPath: archiveDirectory.path) {
            try FileManager.default.removeItem(at: archiveDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    /// Create a base HRVSession suitable for processing.
    private func createBaseSession(
        id: UUID = UUID(),
        startDate: Date? = nil,
        sessionType: SessionType = .overnight,
        linkedSessionIds: [UUID]? = nil
    ) -> HRVSession {
        let resolvedStart = startDate ?? fixedSessionStart
        processedSessionIds.append(id)
        return HRVSession(
            id: id,
            startDate: resolvedStart,
            endDate: nil,
            state: .collecting,
            sessionType: sessionType,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil,
            linkedSessionIds: linkedSessionIds
        )
    }

    /// Default settings snapshot for tests.
    private var defaultSettings: MorningProcessingService.SettingsSnapshot {
        MorningProcessingService.SettingsSnapshot(
            sleepSchedule: SleepSchedule(bedtimeHour: 22, bedtimeMinute: 30, sleepHours: 8.0),
            enableTrainingLoadIntegration: false,
            typicalSleepHours: 8.0,
            scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false,
                isOnTrainingBreak: false,
                enableSleepIntegration: false,
                penalizeMissingSleep: false,
                userAge: nil
            ),
            ansConfig: HRVAnalysisPipeline.ANSConfiguration(
                baselineRMSSD: 40.0,
                vo2Max: nil,
                trainingLoadAdjustment: 0
            )
        )
    }

    // MARK: - processOvernightData Tests

    func testProcessOvernightData_withValidData_producesCompleteSession() async {
        // Arrange: create enough realistic beats for analysis to succeed.
        // ~500 beats at ~800ms each gives roughly 6-7 minutes of data.
        let points = createRealisticPoints(count: 500)
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(24 * 3600))

        // Act
        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 500,
                deviceBeats: nil,
                deviceId: "test-device",
                isBackgroundRefinement: true, // skip sleep polling for test speed
                settings: defaultSettings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        // 500 clean beats clear every analysis minimum (10 clean beats for the
        // time-domain and nonlinear metrics), with or without a window.
        XCTAssertEqual(
            result.session.id,
            baseSession.id,
            "Result session ID should match the base session"
        )
        XCTAssertNotNil(
            result.session.rrSeries,
            "Result session should carry the RR series"
        )
        XCTAssertEqual(
            result.session.rrSeries?.points.count,
            500,
            "Series should contain all input points"
        )

        XCTAssertEqual(result.session.state, .complete)
        XCTAssertNotNil(result.session.analysisResult, "Complete session should have an analysis result")
    }

    func testProcessOvernightData_withInsufficientBeats_handlesShortSeries() async {
        // Arrange: only 10 beats. Behavior may vary by analysis fallback path,
        // but should remain deterministic and never crash.
        let points = createUniformPoints(count: 10)
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(48 * 3600))

        // Act
        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 10,
                deviceBeats: nil,
                deviceId: nil,
                isBackgroundRefinement: true,
                settings: defaultSettings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        XCTAssertEqual(
            result.session.rrSeries?.points.count,
            10,
            "Short-series processing should preserve the input beat count"
        )

        if result.session.state == .complete {
            XCTAssertNotNil(
                result.session.analysisResult,
                "Complete short-series sessions must include analysis output"
            )
            XCTAssertEqual(
                result.session.analysisResult?.cleanBeatCount,
                10,
                "Analysis result should reflect the short input size"
            )
        } else {
            XCTAssertEqual(
                result.session.state,
                .failed,
                "Short-series processing should end in either complete or failed state"
            )
            XCTAssertNil(
                result.session.analysisResult,
                "Failed short-series sessions should not include analysis output"
            )
        }
    }

    func testProcessOvernightData_withHighArtifactRate_handlesGracefully() async {
        // Arrange: create points with extreme values that will be flagged as artifacts.
        // Alternate between very short (200ms) and very long (2500ms) intervals.
        var points: [RRPoint] = []
        var tMs: Int64 = 0
        for i in 0 ..< 400 {
            let rr = (i % 2 == 0) ? 200 : 2500
            points.append(RRPoint(t_ms: tMs, rr_ms: rr))
            tMs += Int64(rr)
        }
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(72 * 3600))

        // Act
        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 400,
                deviceBeats: nil,
                deviceId: nil,
                isBackgroundRefinement: true,
                settings: defaultSettings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        // Assert: should not crash and should produce a session (likely failed)
        XCTAssertNotNil(
            result.session,
            "Service should return a session even with high artifact data"
        )
        XCTAssertEqual(result.session.id, baseSession.id)
        // The verification result should exist
        XCTAssertNotNil(
            result.verificationResult,
            "Verification should have been performed"
        )
    }

    // MARK: - buildMergedSeries Tests (tested via processOvernightData)

    /// An archived overnight recording of 30+ minutes from the same night,
    /// ending within the 4.5 h merge gap of the new one, is merged in front of
    /// it. Times are UTC (pinned in `setUp`): 00:00–00:33 and 04:00 on
    /// 2100-01-01 both fall in the night that opens at 20:00 on Dec 31.
    func testBuildMergedSeries_withLinkedSessions_mergesCorrectly() async throws {
        let existingId = UUID()
        let existingPoints = createRealisticPoints(count: 2_500)
        let existingSeries = RRSeries(points: existingPoints, sessionId: existingId, startDate: fixedSessionStart)
        XCTAssertGreaterThanOrEqual(existingSeries.durationMinutes, 30, "Shorter recordings are never merged")
        let existingSession = HRVSession(
            id: existingId, startDate: fixedSessionStart,
            endDate: fixedSessionStart.addingTimeInterval(existingSeries.durationMinutes * 60), state: .complete,
            sessionType: .overnight, rrSeries: existingSeries, analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(existingSession)

        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(4 * 3600))
        let result = await service.processOvernightData(
            overnightRequest(points: createRealisticPoints(count: 300), baseSession: baseSession)
        )

        XCTAssertEqual(result.sameNightLinks, [existingId], "The earlier recording of the same night is linked")
        XCTAssertEqual(result.session.rrSeries?.points.count, 2_800, "Merged series holds both recordings' beats once")
        XCTAssertEqual(result.session.rrSeries?.startDate, fixedSessionStart, "The merged night starts at the earlier recording")
    }

    /// A streaming request for `points` with the 22:00 bedtime schedule.
    private func overnightRequest(points: [RRPoint], baseSession: HRVSession) -> MorningProcessingService.OvernightRequest {
        let base = defaultSettings
        let settings = MorningProcessingService.SettingsSnapshot(
            sleepSchedule: SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0),
            enableTrainingLoadIntegration: false, typicalSleepHours: 8.0,
            scoringConfig: base.scoringConfig, ansConfig: base.ansConfig
        )
        return MorningProcessingService.OvernightRequest(
            points: points, baseSession: baseSession, dataSource: "streaming", reconnectCount: 0,
            streamingBeats: points.count, deviceBeats: nil, deviceId: nil, isBackgroundRefinement: true,
            settings: settings, trainingContext: nil, cachedTrainingLoad: nil, statusCallback: nil
        )
    }

    func testBuildMergedSeries_withSingleSession_returnsUnmodified() async {
        // Arrange: no other sessions in the archive
        let points = createRealisticPoints(count: 400)
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(96 * 3600))

        // Act
        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 400,
                deviceBeats: nil,
                deviceId: nil,
                isBackgroundRefinement: true,
                settings: defaultSettings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        // Assert: no merging should occur
        XCTAssertTrue(
            result.sameNightLinks.isEmpty,
            "Single session should have no same-night links"
        )
        XCTAssertEqual(
            result.session.rrSeries?.points.count,
            400,
            "Series should contain exactly the input points"
        )
    }

    // MARK: - Merge gap

    private func segment(startHour: Double, hours: Double, id: UUID?) -> MorningProcessingService.NightSegment {
        MorningProcessingService.NightSegment(
            startDate: fixedSessionStart.addingTimeInterval(startHour * 3600),
            points: [RRPoint(t_ms: 0, rr_ms: 1000), RRPoint(t_ms: Int64(hours * 3_600_000), rr_ms: 1000)],
            sessionId: id
        )
    }

    /// The settings footer promises "Segments within 4.5 hours count as one
    /// night"; with a custom 1 h gap, 22:00–23:00 and 05:00–07:00 are two sleeps.
    func testSegmentsBeyondTheMergeGapAreNotMerged() {
        let early = segment(startHour: 0, hours: 1, id: UUID())
        let base = segment(startHour: 7, hours: 2, id: nil)
        let kept = MorningProcessingService.segmentsWithinGap([early, base], gap: 3600)
        XCTAssertEqual(kept.count, 1)
        XCTAssertNil(kept.first?.sessionId, "only the base session survives a 6 h gap under a 1 h setting")
    }

    func testSegmentsWithinTheMergeGapChainIntoOneNight() {
        let first = segment(startHour: 0, hours: 2, id: UUID())
        let second = segment(startHour: 3, hours: 2, id: UUID())
        let base = segment(startHour: 6, hours: 2, id: nil)
        let kept = MorningProcessingService.segmentsWithinGap([base, second, first], gap: 4.5 * 3600)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.map(\.startDate), [first, second, base].map(\.startDate))
    }

    func testMergeOffMeansNoGapAndTheGapIsMeasuredEndToStart() {
        XCTAssertEqual(MorningProcessingService.mergeGap(mode: .off, seconds: 7200), 0)
        XCTAssertEqual(MorningProcessingService.mergeGap(mode: .custom, seconds: 3600), 3600)
        let a = DateInterval(start: fixedSessionStart, duration: 3600)
        let b = DateInterval(start: fixedSessionStart.addingTimeInterval(5400), duration: 3600)
        XCTAssertEqual(MorningProcessingService.gapBetween(b, a), 1800)
        XCTAssertEqual(MorningProcessingService.gapBetween(a, a), 0)
    }

    // MARK: - pollForSleepData Tests (tested indirectly)

    /// No Apple Health sleep (the mock returns none) and too few beats for
    /// the strap's own HR estimate (it needs 100): the poll reports nothing
    /// and leaves the boundaries to the recording.
    func testPollForSleepData_returnsNilWhenNoData() async {
        let points = createRealisticPoints(count: 90)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: fixedSessionStart)

        let result = await service.pollForSleepData(
            series: series, effectiveStartDate: fixedSessionStart, totalBeats: points.count,
            isBackgroundRefinement: true, sleepSchedule: defaultSettings.sleepSchedule, statusCallback: nil
        )

        XCTAssertNil(result.fetchedSleepData)
        XCTAssertNil(result.sleepStartMs)
        XCTAssertNil(result.wakeTimeMs)
        XCTAssertEqual(result.sleepBoundarySource, .recordingBounds)
    }

    // MARK: - computeRecoveryScore Tests (tested indirectly)

    func testComputeRecoveryScore_withValidAnalysis_returnsScore() async throws {
        // Arrange: enough data that analysis should succeed
        let points = createRealisticPoints(count: 500)
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(144 * 3600))

        // Act
        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 500,
                deviceBeats: nil,
                deviceId: nil,
                isBackgroundRefinement: true,
                settings: defaultSettings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        // Every analysed session is scored, on the 0-10 scale.
        XCTAssertEqual(result.session.state, .complete)
        let score = try XCTUnwrap(result.session.recoveryScore, "Complete session should have a recovery score")
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 10.0)
        XCTAssertNotNil(result.session.scoreBreakdown)
    }

    // MARK: - createCompositePoints Tests

    /// Internal 200 beats against streaming 180: both clear the 120-beat
    /// floor and the internal recording is not the shorter one, so
    /// `DataSourceSelector` keeps the internal recording as it is.
    func testCreateCompositePoints_keepsACompleteInternalRecording() throws {
        let sessionId = UUID()
        let startDate = Date().addingTimeInterval(-8 * 3600)

        let internalPoints = createRealisticPoints(count: 200, meanRR: 800)
        let internalSeries = RRSeries(
            points: internalPoints,
            sessionId: sessionId,
            startDate: startDate
        )

        // Streaming series with wall-clock timestamps
        var streamingPoints: [RRPoint] = []
        var tMs: Int64 = 0
        for i in 0 ..< 180 {
            let variation = Int(sin(Double(i) / 50.0) * 40)
            let rr = 800 + variation
            streamingPoints.append(RRPoint(
                t_ms: tMs,
                rr_ms: rr,
                wallClockMs: tMs,
                hr: Int(60000 / Double(rr))
            ))
            tMs += Int64(rr)
        }
        let streamingSeries = RRSeries(
            points: streamingPoints,
            sessionId: sessionId,
            startDate: startDate
        )

        // Act
        let compositePoints = service.createCompositePoints(
            internalSeries: internalSeries,
            streamingSeries: streamingSeries
        )

        XCTAssertEqual(try XCTUnwrap(compositePoints), internalPoints)
    }
}
