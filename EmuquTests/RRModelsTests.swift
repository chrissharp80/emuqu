@testable import Emuqu
import XCTest

final class RRModelsTests: XCTestCase {
    // MARK: - RRPoint

    func testRRPointLegacyInit() {
        let point = RRPoint(t_ms: 1000, rr_ms: 800)
        XCTAssertEqual(point.t_ms, 1000)
        XCTAssertEqual(point.rr_ms, 800)
        XCTAssertNil(point.wallClockMs)
        XCTAssertNil(point.hr)
    }

    func testRRPointFullInit() {
        let point = RRPoint(t_ms: 1000, rr_ms: 800, wallClockMs: 1050, hr: 75)
        XCTAssertEqual(point.t_ms, 1000)
        XCTAssertEqual(point.rr_ms, 800)
        XCTAssertEqual(point.wallClockMs, 1050)
        XCTAssertEqual(point.hr, 75)
    }

    func testRRPointEndMs() {
        let point = RRPoint(t_ms: 1000, rr_ms: 800)
        XCTAssertEqual(point.endMs, 1800)
    }

    func testRRPointMidpointMs() {
        let point = RRPoint(t_ms: 1000, rr_ms: 800)
        XCTAssertEqual(point.midpointMs, 1400.0)
    }

    func testRRPointClockDrift() {
        let point = RRPoint(t_ms: 1000, rr_ms: 800, wallClockMs: 1100)
        XCTAssertEqual(point.clockDriftMs, 100)

        let noWall = RRPoint(t_ms: 1000, rr_ms: 800)
        XCTAssertNil(noWall.clockDriftMs)
    }

    func testRRPointPhysiologicallyValid() {
        let valid = RRPoint(t_ms: 0, rr_ms: 800) // ~75 bpm
        XCTAssertTrue(valid.isPhysiologicallyValid)

        let tooShort = RRPoint(t_ms: 0, rr_ms: 100) // 600 bpm - artifact
        XCTAssertFalse(tooShort.isPhysiologicallyValid)

        let tooLong = RRPoint(t_ms: 0, rr_ms: 5000) // 12 bpm - artifact
        XCTAssertFalse(tooLong.isPhysiologicallyValid)
    }

    func testRRPointCodable() throws {
        let point = RRPoint(t_ms: 1000, rr_ms: 800, wallClockMs: 1050, hr: 75)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(RRPoint.self, from: data)
        XCTAssertEqual(decoded, point)
    }

    func testRRPointEquatable() {
        let a = RRPoint(t_ms: 1000, rr_ms: 800)
        let b = RRPoint(t_ms: 1000, rr_ms: 800)
        let c = RRPoint(t_ms: 1000, rr_ms: 900)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - RRSeries

    func testRRSeriesDurationMs() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 750),
            RRPoint(t_ms: 1550, rr_ms: 900)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        // Duration = last.endMs - first.t_ms = (1550+900) - 0 = 2450
        XCTAssertEqual(series.durationMs, 2450)
    }

    func testRRSeriesDurationMinutes() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 60000, rr_ms: 800)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        // Duration = 60800ms = 1.0133... min
        XCTAssertEqual(series.durationMinutes, 60800.0 / 60000.0, accuracy: 1e-6)
    }

    func testRRSeriesEmptyDuration() {
        let series = RRSeries(points: [], sessionId: UUID(), startDate: Date())
        XCTAssertEqual(series.durationMs, 0)
    }

    func testRRSeriesHasWallClockTimestamps() {
        let withWall = RRSeries(
            points: [RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 0)],
            sessionId: UUID(), startDate: Date()
        )
        XCTAssertTrue(withWall.hasWallClockTimestamps)

        let withoutWall = RRSeries(
            points: [RRPoint(t_ms: 0, rr_ms: 800)],
            sessionId: UUID(), startDate: Date()
        )
        XCTAssertFalse(withoutWall.hasWallClockTimestamps)
    }

    func testRRSeriesAbsoluteTime() throws {
        let start = Date()
        let series = RRSeries(
            points: [RRPoint(t_ms: 0, rr_ms: 800), RRPoint(t_ms: 5000, rr_ms: 800)],
            sessionId: UUID(), startDate: start
        )

        let time0 = try XCTUnwrap(series.absoluteTime(at: 0))
        XCTAssertEqual(time0.timeIntervalSince(start), 0, accuracy: 0.001)

        let time1 = try XCTUnwrap(series.absoluteTime(at: 1))
        XCTAssertEqual(time1.timeIntervalSince(start), 5.0, accuracy: 0.001)

        XCTAssertNil(series.absoluteTime(at: -1))
        XCTAssertNil(series.absoluteTime(at: 5))
    }

    func testRRSeriesRelativeMs() {
        let start = Date()
        let series = RRSeries(points: [], sessionId: UUID(), startDate: start)
        let later = start.addingTimeInterval(5.0)
        XCTAssertEqual(series.relativeMs(from: later), 5000)
    }

    func testRRSeriesDetectGaps() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 0),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 800),
            // 5-second gap in wall clock
            RRPoint(t_ms: 1600, rr_ms: 800, wallClockMs: 6600),
            RRPoint(t_ms: 2400, rr_ms: 800, wallClockMs: 7400)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let gaps = series.detectGaps(thresholdMs: 2000)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].startIndex, 1)
        XCTAssertEqual(gaps[0].endIndex, 2)
    }

    func testRRSeriesNoGaps() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 0),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 800),
            RRPoint(t_ms: 1600, rr_ms: 800, wallClockMs: 1600)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        XCTAssertTrue(series.detectGaps().isEmpty)
    }

    func testRRSeriesEstimatedDataLoss() throws {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 0),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 10000) // Wall clock way ahead
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let loss = series.estimatedDataLossPercent
        XCTAssertNotNil(loss)
        XCTAssertGreaterThan(try XCTUnwrap(loss), 0)
    }

    func testRRSeriesWallClockDuration() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 100),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 5100)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        XCTAssertEqual(series.wallClockDurationMs, 5000)
    }

    func testRRSeriesCodable() throws {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 750)
        ]
        let id = UUID()
        let start = Date()
        let series = RRSeries(points: points, sessionId: id, startDate: start)

        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(RRSeries.self, from: data)

        XCTAssertEqual(decoded.points, series.points)
        XCTAssertEqual(decoded.sessionId, id)
    }

    func testRRSeriesIndexClosestToWallClock() {
        let start = Date()
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 0),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 800),
            RRPoint(t_ms: 1600, rr_ms: 800, wallClockMs: 1600),
            RRPoint(t_ms: 2400, rr_ms: 800, wallClockMs: 2400)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: start)

        let target = start.addingTimeInterval(1.0) // 1000ms
        let idx = series.indexClosestToWallClock(target)
        XCTAssertNotNil(idx)
        XCTAssertTrue(idx == 1 || idx == 2, "Should find closest point to 1000ms")
    }

    // MARK: - ArtifactFlags

    func testArtifactFlagsClean() {
        let clean = ArtifactFlags.clean
        XCTAssertFalse(clean.isArtifact)
        XCTAssertEqual(clean.type, ArtifactFlags.ArtifactType.none)
        XCTAssertEqual(clean.confidence, 1.0)
        XCTAssertFalse(clean.corrected)
    }

    func testArtifactFlagsCodable() throws {
        let flag = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 0.95, corrected: true)
        let data = try JSONEncoder().encode(flag)
        let decoded = try JSONDecoder().decode(ArtifactFlags.self, from: data)
        XCTAssertEqual(decoded, flag)
    }

    // MARK: - TimeDomainMetrics

    func testTimeDomainMetricsCodable() throws {
        let metrics = TimeDomainMetrics(
            meanRR: 800, sdnn: 50, rmssd: 40, pnn50: 25, sdsd: 35,
            meanHR: 75, sdHR: 5, minHR: 60, maxHR: 90, triangularIndex: 12
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(metrics)
        let decoded = try JSONDecoder().decode(TimeDomainMetrics.self, from: data)

        XCTAssertEqual(decoded.meanRR, 800)
        XCTAssertEqual(decoded.rmssd, 40)
        XCTAssertEqual(decoded.minHR, 60)
        XCTAssertEqual(decoded.maxHR, 90)
    }

    func testTimeDomainMetricsLegacyDecoding() throws {
        // Legacy data without minHR/maxHR → should default from SD
        let json = """
        {"schemaVersion":1,"meanRR":800,"sdnn":50,"rmssd":40,"pnn50":25,"sdsd":35,"meanHR":75,"sdHR":5}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TimeDomainMetrics.self, from: data)

        XCTAssertEqual(decoded.minHR, 70, accuracy: 0.01, "minHR should default to meanHR - sdHR")
        XCTAssertEqual(decoded.maxHR, 80, accuracy: 0.01, "maxHR should default to meanHR + sdHR")
    }

    // MARK: - FrequencyDomainMetrics

    func testFrequencyDomainNormalizedUnits() throws {
        let metrics = FrequencyDomainMetrics(vlf: 100, lf: 300, hf: 700, lfHfRatio: 0.429, totalPower: 1100)
        XCTAssertEqual(try XCTUnwrap(metrics.lfNu), 30.0, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(metrics.hfNu), 70.0, accuracy: 0.1)
    }

    func testFrequencyDomainNormalizedUnitsZeroPower() {
        let metrics = FrequencyDomainMetrics(vlf: nil, lf: 0, hf: 0, lfHfRatio: nil, totalPower: 0)
        XCTAssertNil(metrics.lfNu)
        XCTAssertNil(metrics.hfNu)
    }

    // MARK: - TrainingContext

    func testTrainingContextACR() throws {
        let ctx = TrainingContext(
            atl: 60,
            ctl: 40,
            tsb: -20,
            yesterdayTrimp: 100,
            vo2Max: nil,
            daysSinceHardWorkout: nil,
            recentWorkouts: nil
        )
        let acr = try XCTUnwrap(ctx.acuteChronicRatio)
        XCTAssertEqual(acr, 1.5, accuracy: 0.01)
    }

    func testTrainingContextACRZeroCTL() {
        let ctx = TrainingContext(
            atl: 60,
            ctl: 0,
            tsb: 60,
            yesterdayTrimp: 0,
            vo2Max: nil,
            daysSinceHardWorkout: nil,
            recentWorkouts: nil
        )
        XCTAssertNil(ctx.acuteChronicRatio)
    }

    // MARK: - SessionType

    func testSessionTypeDisplayNames() {
        XCTAssertEqual(SessionType.overnight.displayName, "Overnight")
        XCTAssertEqual(SessionType.nap.displayName, "Nap")
        XCTAssertEqual(SessionType.quick.displayName, "Quick Reading")
        XCTAssertEqual(SessionType.breathe.displayName, "Watch Breathe")
    }

    func testSessionTypeIcons() {
        XCTAssertFalse(SessionType.overnight.icon.isEmpty)
        XCTAssertFalse(SessionType.nap.icon.isEmpty)
        XCTAssertFalse(SessionType.quick.icon.isEmpty)
        XCTAssertFalse(SessionType.breathe.icon.isEmpty)
    }

    // MARK: - ReadingTag

    func testSystemTagsCount() {
        XCTAssertEqual(ReadingTag.systemTags.count, 14)
    }

    func testSystemTagsAreMarkedAsSystem() {
        for tag in ReadingTag.systemTags {
            XCTAssertTrue(tag.isSystem, "\(tag.name) should be marked as system")
        }
    }

    func testSystemTagsHaveUniqueIDs() {
        let ids = ReadingTag.systemTags.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "All system tags should have unique IDs")
    }

    func testReadingTagCodable() throws {
        let tag = ReadingTag(name: "Custom", colorHex: "#FF0000", isSystem: false)
        let data = try JSONEncoder().encode(tag)
        let decoded = try JSONDecoder().decode(ReadingTag.self, from: data)
        XCTAssertEqual(decoded.name, "Custom")
        XCTAssertEqual(decoded.colorHex, "#FF0000")
        XCTAssertFalse(decoded.isSystem)
    }

    // MARK: - DeviceProvenance

    func testDeviceProvenanceSamplingNotes() {
        let h10 = DeviceProvenance(
            deviceId: "ABC", deviceModel: "Polar H10", firmwareVersion: "5.0.0",
            recordingMode: .deviceInternal, appVersion: "1.0", osVersion: "17.0", capturedAt: Date()
        )
        XCTAssertTrue(h10.samplingNotes.contains("ECG"))

        let verity = DeviceProvenance(
            deviceId: "DEF", deviceModel: "Polar Verity Sense", firmwareVersion: nil,
            recordingMode: .streaming, appVersion: "1.0", osVersion: "17.0", capturedAt: Date()
        )
        XCTAssertTrue(verity.samplingNotes.contains("optical"))
    }

    func testDeviceProvenanceCodable() throws {
        let prov = DeviceProvenance(
            deviceId: "ABC", deviceModel: "Polar H10", firmwareVersion: "5.0.0",
            recordingMode: .deviceInternal, appVersion: "1.0", osVersion: "17.0", capturedAt: Date()
        )
        let data = try JSONEncoder().encode(prov)
        let decoded = try JSONDecoder().decode(DeviceProvenance.self, from: data)
        XCTAssertEqual(decoded.deviceId, "ABC")
        XCTAssertEqual(decoded.recordingMode, .deviceInternal)
    }

    // MARK: - OfflineSession

    func testOfflineSessionNeedsSync() {
        let session = HRVSession(startDate: Date())
        var offline = OfflineSession(session: session)

        XCTAssertTrue(offline.needsSync)

        offline.syncedAt = Date()
        XCTAssertFalse(offline.needsSync)
    }

    func testOfflineSessionMaxRetries() {
        let session = HRVSession(startDate: Date())
        var offline = OfflineSession(session: session)
        offline.syncAttempts = 3

        XCTAssertFalse(offline.needsSync, "Should stop syncing after 3 attempts")
    }
}
