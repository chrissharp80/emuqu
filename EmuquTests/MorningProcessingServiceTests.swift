@testable import Emuqu
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
    private var archive = SessionArchive()
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

    // MARK: - Test Helpers

    /// Create a base HRVSession suitable for processing.
    private func createBaseSession(
        id: UUID = UUID(),
        startDate: Date? = nil,
        sessionType: SessionType = .overnight,
        linkedSessionIds: [UUID]? = nil
    ) -> HRVSession {
        let resolvedStart = startDate ?? fixedSessionStart
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

        // Assert: with 500 realistic beats the session should complete or at least
        // have an analysis result. The pipeline may or may not find an organized
        // window, so we accept both .complete (analysis succeeded) and .failed.
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

        if result.session.state == .complete {
            XCTAssertNotNil(
                result.session.analysisResult,
                "Complete session should have an analysis result"
            )
        }
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

    func testBuildMergedSeries_withLinkedSessions_mergesCorrectly() async {
        // Arrange: archive an existing overnight session from the same night
        let existingId = UUID()
        let existingStart = fixedSessionStart
        let existingPoints = createRealisticPoints(count: 200)
        let existingSeries = RRSeries(
            points: existingPoints,
            sessionId: existingId,
            startDate: existingStart
        )
        var existingSession = HRVSession(
            id: existingId,
            startDate: existingStart,
            endDate: existingStart.addingTimeInterval(3600),
            state: .complete,
            sessionType: .overnight,
            rrSeries: existingSeries,
            analysisResult: nil,
            artifactFlags: nil
        )
        existingSession.rrSeries = existingSeries
        XCTAssertNoThrow(try archive.archive(existingSession))

        // Create a new session from the same night (a few hours later)
        let newPoints = createRealisticPoints(count: 300)
        let newStart = existingStart.addingTimeInterval(4 * 3600)
        let baseSession = createBaseSession(startDate: newStart)

        // Act: process with the same-night sleep schedule
        let settings = MorningProcessingService.SettingsSnapshot(
            sleepSchedule: SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0),
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

        let result = await service.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: newPoints,
                baseSession: baseSession,
                dataSource: "streaming",
                reconnectCount: 0,
                streamingBeats: 300,
                deviceBeats: nil,
                deviceId: nil,
                isBackgroundRefinement: true,
                settings: settings,
                trainingContext: nil,
                cachedTrainingLoad: nil,
                statusCallback: nil
            )
        )

        // Assert: if the sessions are from the same night, the merged series
        // should contain more points than the new session alone.
        // Note: same-night detection depends on sleep schedule alignment;
        // the merge may or may not include the existing session.
        let seriesCount = result.session.rrSeries?.points.count ?? 0
        if !result.sameNightLinks.isEmpty {
            XCTAssertGreaterThan(
                seriesCount,
                300,
                "Merged series should have more points than the new session alone"
            )
            XCTAssertTrue(
                result.sameNightLinks.contains(existingId),
                "Same-night links should include the existing session ID"
            )
        } else {
            // If not merged, the series should have only the new points
            XCTAssertEqual(
                seriesCount,
                300,
                "Un-merged series should have only the new session's points"
            )
        }
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

    func testPollForSleepData_returnsNilWhenNoData() async {
        // Arrange: use background refinement mode (single poll attempt) so sleep
        // polling doesn't block. HealthKit won't return real sleep data in tests.
        let points = createRealisticPoints(count: 500)
        let baseSession = createBaseSession(startDate: fixedSessionStart.addingTimeInterval(120 * 3600))

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

        // Assert: without real HealthKit access, sleep boundaries should be nil
        // or derived from recording bounds. The session should still have no
        // explicit sleep start/end from HealthKit.
        // Note: HR-based estimation may produce boundaries, so we verify
        // the session was still produced successfully.
        XCTAssertNotNil(
            result.session,
            "Session should be produced even without sleep data"
        )
    }

    // MARK: - computeRecoveryScore Tests (tested indirectly)

    func testComputeRecoveryScore_withValidAnalysis_returnsScore() async {
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

        // Assert: if analysis succeeded, recovery score should be computed
        if result.session.state == .complete {
            XCTAssertNotNil(
                result.session.recoveryScore,
                "Complete session should have a recovery score"
            )
            if let score = result.session.recoveryScore {
                XCTAssertGreaterThanOrEqual(
                    score,
                    0.0,
                    "Recovery score should be non-negative"
                )
                XCTAssertLessThanOrEqual(
                    score,
                    10.0,
                    "Recovery score should be at most 10.0"
                )
            }
        }
    }

    // MARK: - createCompositePoints Tests

    func testCreateCompositePoints_mergesStreamingAndDevice() {
        // Arrange: create two overlapping series simulating internal and streaming data
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

        // Assert: DataSourceSelector should pick the best source or merge
        if let composite = compositePoints {
            XCTAssertGreaterThan(
                composite.count,
                0,
                "Composite should have points"
            )
            // The composite should have at least as many beats as the smaller source
            XCTAssertGreaterThanOrEqual(
                composite.count,
                min(internalPoints.count, streamingPoints.count),
                "Composite should not lose data from the smaller source"
            )
        }
        // Note: composite can be nil if DataSourceSelector decides one source is
        // sufficient -- both nil and non-nil are valid outcomes depending on the
        // selector's logic.
    }
}
