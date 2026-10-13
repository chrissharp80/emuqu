@testable import Emuqu
import XCTest

@MainActor
final class HRVSessionTests: XCTestCase {
    /// The copy these tests assert is English; the app's language follows
    /// the host's unless pinned.
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    // MARK: - Initialization

    func testDefaultInit() {
        let session = HRVSession(startDate: Date())
        XCTAssertEqual(session.state, .collecting)
        XCTAssertEqual(session.sessionType, .overnight)
        XCTAssertTrue(session.tags.isEmpty)
        XCTAssertNil(session.endDate)
        XCTAssertNil(session.rrSeries)
        XCTAssertNil(session.analysisResult)
        XCTAssertNil(session.recoveryScore)
        XCTAssertNil(session.notes)
    }

    func testInitWithCustomSessionType() {
        let session = HRVSession(startDate: Date(), sessionType: .nap)
        XCTAssertEqual(session.sessionType, .nap)
    }

    func testInitWithTags() {
        let tags: [ReadingTag] = [.morning, .stressed]
        let session = HRVSession(startDate: Date(), tags: tags)
        XCTAssertEqual(session.tags.count, 2)
    }

    // MARK: - Duration

    func testDurationWithEndDate() throws {
        var session = HRVSession(startDate: Date())
        session.endDate = session.startDate.addingTimeInterval(3600)
        let duration = try XCTUnwrap(session.duration)
        XCTAssertEqual(duration, 3600, accuracy: 0.01)
    }

    func testDurationWithoutEndDate() {
        let session = HRVSession(startDate: Date())
        XCTAssertNil(session.duration)
    }

    // MARK: - Valid for Analysis

    func testIsValidForAnalysisNoSeries() {
        let session = HRVSession(startDate: Date())
        XCTAssertFalse(session.isValidForAnalysis)
    }

    func testIsValidForAnalysisTooFewPoints() {
        var session = HRVSession(startDate: Date())
        let points = (0 ..< 50).map { RRPoint(t_ms: Int64($0 * 800), rr_ms: 800) }
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: session.startDate)
        XCTAssertFalse(session.isValidForAnalysis)
    }

    func testIsValidForAnalysisEnoughPoints() {
        var session = HRVSession(startDate: Date())
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0 * 800), rr_ms: 800) }
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: session.startDate)
        XCTAssertTrue(session.isValidForAnalysis)
    }

    // MARK: - Resumable

    func testIsResumable() {
        var session = HRVSession(startDate: Date())
        session.state = .paused
        XCTAssertTrue(session.isResumable)

        session.state = .complete
        XCTAssertFalse(session.isResumable)

        session.state = .collecting
        XCTAssertFalse(session.isResumable)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        var session = HRVSession(startDate: Date(), tags: [.morning], sessionType: .overnight)
        session.endDate = session.startDate.addingTimeInterval(28800)
        session.state = .complete
        session.recoveryScore = 7.5
        session.notes = "Test session"
        session.sleepStartMs = 1000
        session.sleepEndMs = 25_000_000

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.state, .complete)
        XCTAssertEqual(decoded.sessionType, .overnight)
        XCTAssertEqual(decoded.recoveryScore, 7.5)
        XCTAssertEqual(decoded.notes, "Test session")
        XCTAssertEqual(decoded.sleepStartMs, 1000)
        XCTAssertEqual(decoded.sleepEndMs, 25_000_000)
        XCTAssertEqual(decoded.tags.count, 1)
    }

    func testCodableLegacyDataWithMissingFields() throws {
        // Simulate legacy JSON without sessionType, sleepStartMs, etc.
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789ABC",
            "startDate": "2026-01-01T00:00:00Z",
            "state": "complete"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(HRVSession.self, from: data)

        XCTAssertEqual(session.sessionType, .overnight, "Should default to overnight")
        XCTAssertTrue(session.tags.isEmpty, "Should default to empty tags")
        XCTAssertNil(session.sleepStartMs)
        XCTAssertNil(session.deviceProvenance)
        XCTAssertNil(session.linkedSessionIds)
    }

    func testSchemaVersionEncoded() throws {
        let session = HRVSession(startDate: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let jsonObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(jsonObj["schemaVersion"] as? Int, HRVSession.currentSchemaVersion)
    }

    // MARK: - Skip RR Series (Lightweight Decoding)

    func testSkipRRSeriesDecoding() throws {
        var session = HRVSession(startDate: Date())
        let points = (0 ..< 10).map { RRPoint(t_ms: Int64($0 * 800), rr_ms: 800) }
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: session.startDate)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        // Decode with skipRRSeries flag
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.skipRRSeries] = true
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertNil(decoded.rrSeries, "rrSeries should be nil when skipRRSeries is set")
        XCTAssertEqual(decoded.id, session.id)
    }

    // MARK: - DataSourceSummary

    func testDataSourceSummaryCompositeDescription() {
        let summary = HRVSession.DataSourceSummary(
            selectedSource: "composite", streamingBeats: 1000, deviceBeats: 1200,
            totalBeats: 1500, beatDifferencePercent: 50.0, reconnectCount: 2
        )
        XCTAssertTrue(summary.description.contains("merged"))
    }

    func testDataSourceSummaryStreamingDescription() {
        let summary = HRVSession.DataSourceSummary(
            selectedSource: "streaming", streamingBeats: 1000, deviceBeats: nil,
            totalBeats: 1000, beatDifferencePercent: nil, reconnectCount: 0
        )
        XCTAssertTrue(summary.description.contains("Streamed"))
    }

    func testDataSourceSummaryVeritySense() {
        let summary = HRVSession.DataSourceSummary(
            selectedSource: "streaming", streamingBeats: 1000, deviceBeats: nil,
            totalBeats: 1000, beatDifferencePercent: nil, reconnectCount: 0,
            deviceModel: "Polar Verity Sense"
        )
        XCTAssertTrue(summary.description.contains("Verity Sense"))
    }

    func testDataSourceSummaryInternalDescription() {
        let summary = HRVSession.DataSourceSummary(
            selectedSource: "internal", streamingBeats: 500, deviceBeats: 1200,
            totalBeats: 1200, beatDifferencePercent: nil, reconnectCount: 0
        )
        XCTAssertTrue(summary.description.contains("Strap"))
    }

    // MARK: - SessionArchiveEntry

    func testSessionArchiveEntryCodable() throws {
        let entry = SessionArchiveEntry(
            sessionId: UUID(), date: Date(), endDate: Date(),
            fileHash: "abc123", filePath: "/sessions/test.json",
            recoveryScore: 8.0, meanRMSSD: 45.0, tags: [.morning],
            sessionType: .overnight
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionArchiveEntry.self, from: data)

        XCTAssertEqual(decoded.sessionId, entry.sessionId)
        XCTAssertEqual(decoded.recoveryScore, 8.0)
        XCTAssertEqual(decoded.meanRMSSD, 45.0)
        XCTAssertEqual(decoded.sessionType, .overnight)
    }

    func testSessionArchiveEntryDisplayDate() {
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(28800)

        let overnightEntry = SessionArchiveEntry(
            sessionId: UUID(), date: startDate, endDate: endDate,
            fileHash: "abc", filePath: "test", sessionType: .overnight
        )
        XCTAssertEqual(overnightEntry.displayDate, endDate)

        let napEntry = SessionArchiveEntry(
            sessionId: UUID(), date: startDate, endDate: endDate,
            fileHash: "abc", filePath: "test", sessionType: .nap
        )
        XCTAssertEqual(napEntry.displayDate, startDate)
    }

    func testSessionArchiveEntryLegacyDecoding() throws {
        let json = """
        {
            "sessionId": "12345678-1234-1234-1234-123456789ABC",
            "date": "2026-01-01T00:00:00Z",
            "fileHash": "abc",
            "filePath": "test.json"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(SessionArchiveEntry.self, from: data)

        XCTAssertEqual(entry.sessionType, .overnight, "Should default to overnight")
        XCTAssertTrue(entry.tags.isEmpty)
        XCTAssertNil(entry.recoveryScore)
    }

    // MARK: - SleepSegmentMs

    func testSleepSegmentMsEquatable() {
        let a = HRVSession.SleepSegmentMs(startMs: 1000, endMs: 5000)
        let b = HRVSession.SleepSegmentMs(startMs: 1000, endMs: 5000)
        let c = HRVSession.SleepSegmentMs(startMs: 2000, endMs: 5000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ImportedMetrics

    func testImportedMetricsCodable() throws {
        let metrics = HRVSession.ImportedMetrics(
            rmssd: 45.0, rmssdRaw: 48.0, artifactPercent: 3.0,
            source: "Elite HRV", sdnn: 55.0
        )
        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(HRVSession.ImportedMetrics.self, from: data)
        XCTAssertEqual(decoded.rmssd, 45.0)
        XCTAssertEqual(decoded.sdnn, 55.0)
        XCTAssertEqual(decoded.source, "Elite HRV")
    }

    // MARK: - Legacy Elite HRV imports

    /// A session as an earlier build wrote it: the result has no
    /// `estimatedMetrics` key at all.
    private func roundTrip(_ session: HRVSession) throws -> HRVSession {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HRVSession.self, from: encoder.encode(session))
    }

    private func importedSession(source: String, result: HRVAnalysisResult) -> HRVSession {
        HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil, state: .complete,
            rrSeries: nil, analysisResult: result, artifactFlags: nil,
            importedMetrics: HRVSession.ImportedMetrics(rmssd: 45, rmssdRaw: 45, artifactPercent: 0, source: source)
        )
    }

    func testLegacyEliteImportDecodesWithEveryDerivedMetricMarkedEstimated() throws {
        let legacy = importedSession(source: "Elite HRV", result: SnapshotFixtures.legacyEliteImportResult())
        XCTAssertNil(legacy.analysisResult?.estimatedMetrics, "Fixture is the pre-provenance shape")

        let decoded = try roundTrip(legacy)
        let result = try XCTUnwrap(decoded.analysisResult)

        let derived = EstimatedMetric.allCases.filter { $0 != .hrRange && $0 != .beatCount }
        XCTAssertEqual(Set(result.estimatedMetrics ?? []), Set(derived.map(\.rawValue)), "The file's own beat count and HR range are kept")
        XCTAssertNil(result.measuredSDNN)
        XCTAssertNil(result.measuredPNN50)
        XCTAssertNil(result.ansMetrics, "The old importer's stress index was made from RMSSD")
        XCTAssertNil(decoded.stressIndex)
        XCTAssertEqual(result.timeDomain.rmssd, 45.0, "RMSSD was Elite HRV's own value and is kept")
    }

    /// The old importer's stand-ins: 100 beats and a 60–100 bpm range, or a
    /// range of mean HR ±15%.
    func testLegacyEliteStandInBeatCountAndRangeAreMarkedEstimated() throws {
        let defaults = SnapshotFixtures.legacyEliteImportResult(beats: 100, minHR: 60, maxHR: 100)
        let fromDefaults = try XCTUnwrap(try roundTrip(importedSession(source: "Elite HRV", result: defaults)).analysisResult)
        XCTAssertEqual(Set(fromDefaults.estimatedMetrics ?? []), Set(EstimatedMetric.allCases.map(\.rawValue)))

        let meanRR = 900.0
        let derived = SnapshotFixtures.legacyEliteImportResult(minHR: 60_000 / (meanRR * 1.15), maxHR: 60_000 / (meanRR * 0.85))
        let fromMeanHR = try XCTUnwrap(try roundTrip(importedSession(source: "Elite HRV", result: derived)).analysisResult)
        XCTAssertTrue(fromMeanHR.isEstimated(.hrRange))
        XCTAssertFalse(fromMeanHR.isEstimated(.beatCount))
    }

    func testLegacyEliteMarkerSurvivesASecondSave() throws {
        let once = try roundTrip(importedSession(source: "Elite HRV", result: SnapshotFixtures.legacyEliteImportResult()))
        let twice = try roundTrip(once)
        XCTAssertEqual(twice.analysisResult?.estimatedMetrics, once.analysisResult?.estimatedMetrics)
    }

    func testNewEliteImportKeepsItsOwnMarker() throws {
        var result = SnapshotFixtures.analysisResult()
        result.estimatedMetrics = [EstimatedMetric.sdsd.rawValue]

        let decoded = try roundTrip(importedSession(source: "Elite HRV", result: result))

        XCTAssertEqual(decoded.analysisResult?.estimatedMetrics, [EstimatedMetric.sdsd.rawValue])
        XCTAssertEqual(decoded.analysisResult?.measuredSDNN, 54.0, "The file's SDNN is a measurement")
        XCTAssertNotNil(decoded.analysisResult?.ansMetrics)
    }

    /// The first Elite importer also stored an RMSSD-made readiness as the
    /// session's score; it goes with the analysis it was made from.
    func testLegacyEliteImportDecodesWithoutItsScore() throws {
        var legacy = importedSession(source: "Elite HRV", result: SnapshotFixtures.legacyEliteImportResult())
        legacy.recoveryScore = 6.5
        legacy.frozenReadiness = 6.5

        let decoded = try roundTrip(legacy)

        XCTAssertNil(decoded.recoveryScore)
        XCTAssertNil(decoded.frozenReadiness)
        XCTAssertNil(decoded.scoreBreakdown)
    }

    func testRecordedSessionUnderAnEliteSourceKeepsItsScore() throws {
        var merged = importedSession(source: "Elite HRV", result: SnapshotFixtures.analysisResult())
        merged.recoveryScore = 7.1

        XCTAssertEqual(try roundTrip(merged).recoveryScore, 7.1)
    }

    func testOtherImportsAndRecordedSessionsDecodeUnmarked() throws {
        let other = try roundTrip(importedSession(source: "test", result: SnapshotFixtures.legacyEliteImportResult()))
        XCTAssertNil(other.analysisResult?.estimatedMetrics)
        XCTAssertEqual(other.analysisResult?.measuredSDNN, 81)
        XCTAssertEqual(other.stressIndex, 18.2)
    }

    /// A recorded night that took an Elite import's `importedMetrics` in a
    /// merge keeps its own analysis: RR analysis never stores SDSD == RMSSD.
    func testRecordedAnalysisUnderAnEliteSourceIsNotMarked() throws {
        let merged = try roundTrip(importedSession(source: "Elite HRV", result: SnapshotFixtures.analysisResult()))
        XCTAssertNil(merged.analysisResult?.estimatedMetrics)
        XCTAssertEqual(merged.analysisResult?.measuredSDNN, 54.0)
        XCTAssertEqual(merged.stressIndex, 120)
    }
}
