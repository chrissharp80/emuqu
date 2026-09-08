@testable import Emuqu
import XCTest

/// Tests for crediting daytime naps toward the recovery score's sleep DURATION:
/// the score effect, the pure nap-aggregation logic, the nap window, and the
/// SleepData nap plumbing / Codable back-compat.
final class NapSleepCreditTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Score effect

    /// A 3h night alone reads as sleep debt; the same night plus a qualifying 3h
    /// nap (6h total) must score strictly higher — nap minutes count toward the
    /// 24h duration and relax the duration-debt ceiling.
    func testNapRaisesShortNightSleepScore() throws {
        let shortNight = SleepData(
            date: baseDate, totalSleepMinutes: 180, inBedMinutes: 195,
            deepSleepMinutes: 30, remSleepMinutes: 40,
            awakeMinutes: 15, sleepEfficiency: 92, boundarySource: .healthKit
        )
        let withNap = shortNight.withNapSleepMinutes(180)

        let noNap = RecoveryScoreCalculator.calculateSleepScore(
            sleepData: shortNight, typicalSleepHours: 8.0, userAge: 40
        )
        let napped = RecoveryScoreCalculator.calculateSleepScore(
            sleepData: withNap, typicalSleepHours: 8.0, userAge: 40
        )
        let nappedScore = try XCTUnwrap(napped)
        let noNapScore = try XCTUnwrap(noNap)
        XCTAssertGreaterThan(
            nappedScore, noNapScore,
            "A qualifying nap must raise a short night's sleep score"
        )
    }

    /// The nap only affects duration: night-only architecture totals are untouched.
    func testNapLeavesNightArchitectureUntouched() {
        let night = SleepData(
            date: baseDate, totalSleepMinutes: 300, inBedMinutes: 310,
            deepSleepMinutes: 60, remSleepMinutes: 75,
            awakeMinutes: 10, sleepEfficiency: 96, boundarySource: .healthKit
        )
        let withNap = night.withNapSleepMinutes(120)
        XCTAssertEqual(withNap.nightSleepMinutes, 300)
        XCTAssertEqual(withNap.deepSleepMinutes, 60)
        XCTAssertEqual(withNap.remSleepMinutes, 75)
        XCTAssertEqual(withNap.totalSleepIncludingNapMinutes, 420)
        XCTAssertEqual(night.totalSleepIncludingNapMinutes, 300, "No nap → 24h total equals the night")
    }

    /// A non-positive nap clears the field rather than storing 0 / negatives.
    func testNonPositiveNapClearsField() {
        let night = SleepData(
            date: baseDate, totalSleepMinutes: 300, inBedMinutes: 300,
            awakeMinutes: 0, sleepEfficiency: 100, boundarySource: .healthKit
        )
        XCTAssertNil(night.withNapSleepMinutes(0).napSleepMinutes)
        XCTAssertNil(night.withNapSleepMinutes(-5).napSleepMinutes)
    }

    // MARK: - Codable back-compat

    func testCodableRoundTripPreservesNap() throws {
        let night = SleepData(
            date: baseDate, totalSleepMinutes: 200, inBedMinutes: 210,
            napSleepMinutes: 95, awakeMinutes: 10, sleepEfficiency: 95,
            boundarySource: .healthKit
        )
        let decoded = try JSONDecoder().decode(
            SleepData.self, from: JSONEncoder().encode(night)
        )
        XCTAssertEqual(decoded.napSleepMinutes, 95)
    }

    /// Data without a nap (the legacy shape — the field is absent/null) decodes
    /// to nil, and the 24h total falls back to the night alone.
    func testMissingNapDecodesToNil() throws {
        let legacy = SleepData(
            date: baseDate, totalSleepMinutes: 200, inBedMinutes: 210,
            awakeMinutes: 10, sleepEfficiency: 95, boundarySource: .healthKit
        )
        let decoded = try JSONDecoder().decode(
            SleepData.self, from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(decoded.napSleepMinutes)
        XCTAssertEqual(decoded.totalSleepIncludingNapMinutes, 200)
    }

    // MARK: - Nap aggregation (episode grouping / floor / union)

    private func iv(_ startMin: Double, _ endMin: Double) -> (start: Date, end: Date) {
        (baseDate.addingTimeInterval(startMin * 60), baseDate.addingTimeInterval(endMin * 60))
    }

    private func aggregate(_ intervals: [(start: Date, end: Date)]) -> Int {
        HealthKitManager.qualifyingNapMinutes(
            asleepIntervals: intervals, episodeGapSeconds: 60 * 60, floorSeconds: 20 * 60
        )
    }

    func testLongNapCounts() {
        XCTAssertEqual(aggregate([iv(0, 90)]), 90)
    }

    func testShortNapBelowFloorIgnored() {
        XCTAssertEqual(aggregate([iv(0, 15)]), 0)
    }

    func testSeparateEpisodesEachGetTheFloor() {
        // A 40-min morning nap and a 10-min afternoon microsleep (>60m apart):
        // only the 40-min episode clears the floor.
        XCTAssertEqual(aggregate([iv(0, 40), iv(200, 210)]), 40)
    }

    func testOverlappingSamplesCountOnce() {
        // Overlapping stage samples in one episode union to 60, not 75.
        XCTAssertEqual(aggregate([iv(0, 45), iv(30, 60)]), 60)
    }

    func testNearbySamplesFormOneEpisode() {
        // Two 15-min samples 10 min apart (< gap) → one episode, 30 asleep min,
        // clears the 20-min floor.
        XCTAssertEqual(aggregate([iv(0, 15), iv(25, 40)]), 30)
    }

    func testEmptyIntervalsYieldZero() {
        XCTAssertEqual(aggregate([]), 0)
        XCTAssertEqual(aggregate([iv(30, 30)]), 0) // zero-length dropped
    }

    // MARK: - Nap window

    func testNapWindowIsTheGapBetweenNights() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let window = schedule.daytimeNapWindow(relativeTo: baseDate)
        // Ends exactly where this night's overnight window begins — no evening overlap.
        XCTAssertEqual(window.end, schedule.overnightWindowStart(relativeTo: baseDate))
        XCTAssertLessThan(window.start, window.end)
        // Starts at the prior night's overnight-window end (this morning's wake +
        // 4.5h), so a morning back-to-sleep can never be counted as a nap.
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: window.end)
        let wake = TestDate.settingTime(
            hour: schedule.wakeHour,
            minute: schedule.wakeMinute,
            of: dayStart,
            calendar: cal
        )
        XCTAssertEqual(window.start.timeIntervalSince(wake), 4.5 * 3600, accuracy: 1)
    }

    /// AM bedtime (2 AM sleeper) must still produce a sane daytime gap that ends
    /// at the overnight-window start and never runs into a night.
    func testNapWindowAMBedtime() {
        let schedule = SleepSchedule(bedtimeHour: 2, bedtimeMinute: 0, sleepHours: 6.0) // bed 2 AM, wake 8 AM
        let cal = Calendar.current
        let anchor = TestDate.settingTime(hour: 2, of: baseDate, calendar: cal)
        let window = schedule.daytimeNapWindow(relativeTo: anchor)
        XCTAssertEqual(window.end, schedule.overnightWindowStart(relativeTo: anchor))
        let len = window.end.timeIntervalSince(window.start)
        XCTAssertGreaterThan(len, 0)
        XCTAssertLessThanOrEqual(len, 14 * 3600) // a plausible waking-day gap, not a runaway window
    }
}
