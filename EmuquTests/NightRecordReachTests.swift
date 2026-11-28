@testable import Emuqu
import XCTest

/// What a night stores must be reachable by date: the analysis window and
/// peak capacity on the HRV record, bedtime and wake time on the sleep
/// record, the morning feeling of a night without a score, the stored score
/// breakdown, the night's heart-rate curve, and the naps and quick readings
/// of a day that also had an overnight.
@MainActor
final class NightRecordReachTests: XCTestCase {
    private let day = "2026-02-20"
    private let partialDay = "2026-02-22"

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightRecordReachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func date(day: Int, hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: day, hour: hour)) ?? Date()
    }

    private var nightStart: Date { date(day: 19, hour: 23) }

    private func analysis(rmssd: Double) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: rmssd, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12)
        let nonlinear = NonlinearMetrics(sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: 0.8, dfaAlpha1R2: 0.95)
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400, timeDomain: timeDomain,
            frequencyDomain: FrequencyDomainMetrics(vlf: 300, lf: 900, hf: 700, lfHfRatio: 1.3, totalPower: 1900),
            nonlinear: nonlinear, ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: Date()
        )
        result.windowStartMs = 600_000
        result.windowEndMs = 900_000
        result.windowSelectionReason = "Highest stable plateau"
        result.windowClassification = "Organized Recovery"
        result.windowRelativePosition = 0.4
        result.windowHRStability = 2.5
        result.isConsolidated = true
        result.isOrganizedRecovery = true
        result.peakCapacity = PeakCapacity(
            peakRMSSD: 81, peakSDNN: 92, peakTotalPower: 2500, windowDurationMinutes: 5, windowRelativePosition: 0.5, windowMeanHR: 52
        )
        return result
    }

    /// An hour of beats: 60 bpm for the first half hour, 50 bpm after, each
    /// alternating 10 ms either side so RMSSD is 20 ms.
    private func series(for id: UUID) -> RRSeries {
        var points: [RRPoint] = []
        var tMs: Int64 = 0
        while tMs < 3_600_000 {
            let base = tMs < 1_800_000 ? 1000 : 1200
            let rr = base + (points.count.isMultiple(of: 2) ? -10 : 10)
            points.append(RRPoint(t_ms: tMs, rr_ms: rr))
            tMs += Int64(rr)
        }
        return RRSeries(points: points, sessionId: id, startDate: nightStart)
    }

    private func sleep() -> SleepData {
        SleepData(
            date: nightStart, inBedStart: nightStart.addingTimeInterval(300), sleepStart: nightStart.addingTimeInterval(900),
            sleepEnd: nightStart.addingTimeInterval(7 * 3600), totalSleepMinutes: 400, inBedMinutes: 420, deepSleepMinutes: 60,
            remSleepMinutes: 90, napSleepMinutes: 25, awakeMinutes: 20, sleepEfficiency: 95, boundarySource: .healthKit,
            hrSleepQuality: HRSleepQuality(avgSleepRMSSD: 48, restorativeSleepMinutes: 120, restorativeSleepRatio: 0.3, avgSleepHR: 55, minSleepHR: 47)
        )
    }

    private func breakdown() -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = [
            RecoveryScoreCalculator.ScoreFactor(label: "HRV", detail: "Below baseline", score: 50, weight: 0.6, impact: .negative),
            RecoveryScoreCalculator.ScoreFactor(label: "Sleep", detail: "Good sleep", score: 80, weight: 0.25, impact: .positive),
            RecoveryScoreCalculator.ScoreFactor(label: "Vitals", detail: "Normal", score: 90, weight: 0.15, impact: .neutral)
        ]
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 54.5, tier: 3, factors: factors, penalties: ["SpO2 below 95%: -10"], spo2PenaltyApplied: true
        )
    }

    private func overnight() -> HRVSession {
        var session = HRVSession(startDate: nightStart, tags: [], sessionType: .overnight)
        session.endDate = nightStart.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = 5.45
        session.analysisResult = analysis(rmssd: 45)
        session.rrSeries = series(for: session.id)
        session.sleepSnapshot = sleep()
        session.scoreBreakdown = breakdown()
        return session
    }

    private func reading(_ type: SessionType, start: Date, minutes: Double, quality: HRVDataQuality, rmssd: Double) -> HRVSession {
        var session = HRVSession(startDate: start, tags: [], sessionType: type)
        session.endDate = start.addingTimeInterval(minutes * 60)
        session.state = .complete
        session.hrvDataQuality = quality
        session.analysisResult = analysis(rmssd: rmssd)
        return session
    }

    /// A night that stopped before sleep: no score, but the user said how
    /// they felt and wrote a note.
    private func partialNight() -> HRVSession {
        var session = reading(.overnight, start: date(day: 21, hour: 23), minutes: 300, quality: .preSleep, rmssd: 30)
        session.morningFeeling = 2
        session.morningFeelingTags = [.infection]
        session.notes = "Felt feverish"
        return session
    }

    private func makeRegistry() throws -> FactResolverRegistry {
        let archive = SessionArchive(directory: temporaryDirectory())
        let sessions = [
            overnight(),
            reading(.nap, start: date(day: 20, hour: 14), minutes: 30, quality: .good, rmssd: 62),
            reading(.quick, start: date(day: 20, hour: 18), minutes: 5, quality: .insufficient, rmssd: 25),
            partialNight()
        ]
        for session in sessions {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        return AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
    }

    // MARK: - Value readers

    private func record(_ value: FactValue?, file: StaticString = #filePath, line: UInt = #line) -> [String: FactValue] {
        guard case let .record(fields) = value else {
            XCTFail("expected a record, got \(String(describing: value))", file: file, line: line)
            return [:]
        }
        return fields
    }

    private func list(_ value: FactValue?, file: StaticString = #filePath, line: UInt = #line) -> [[String: FactValue]] {
        guard case let .list(items) = value else {
            XCTFail("expected a list, got \(String(describing: value))", file: file, line: line)
            return []
        }
        return items.map { record($0, file: file, line: line) }
    }

    private func number(_ value: FactValue?) -> Double? {
        switch value {
        case let .double(number): number
        case let .integer(number): Double(number)
        default: nil
        }
    }

    private func text(_ value: FactValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }

    private func flag(_ value: FactValue?) -> Bool? {
        if case let .boolean(flag) = value { return flag }
        return nil
    }

    private func time(_ value: FactValue?) -> Date? {
        if case let .date(time) = value { return time }
        return nil
    }

    private func lookup(_ registry: FactResolverRegistry, _ key: String) async -> FactValue {
        await CompactToolRouter(registry: registry).resolveTool(name: "lookup_fact", argsJSON: #"{"key":"\#(key)"}"#)
    }

    private func tool(_ registry: FactResolverRegistry, _ name: String, _ args: String) async -> FactValue {
        await CompactToolRouter(registry: registry).resolveTool(name: name, argsJSON: args)
    }

    // MARK: - HRV record: analysis window and peak capacity

    func testTheHRVRecordCarriesTheAnalysisWindowAndPeakCapacity() async throws {
        let registry = try makeRegistry()
        let fields = record(await tool(registry, "get_hrv", #"{"which":"by_date","date":"\#(day)"}"#))
        XCTAssertEqual(time(fields["window_start_iso"]), nightStart.addingTimeInterval(600))
        XCTAssertEqual(time(fields["window_end_iso"]), nightStart.addingTimeInterval(900))
        XCTAssertEqual(text(fields["window_selection_reason"]), "Highest stable plateau")
        XCTAssertEqual(text(fields["window_classification"]), "Organized Recovery")
        XCTAssertEqual(flag(fields["is_consolidated"]), true)
        XCTAssertEqual(flag(fields["is_organized_recovery"]), true)
        XCTAssertEqual(number(fields["window_relative_position"]), 0.4)
        XCTAssertEqual(number(fields["window_hr_stability"]), 2.5)
        XCTAssertEqual(number(fields["peak_rmssd_ms"]), 81)
        XCTAssertEqual(number(fields["peak_sdnn_ms"]), 92)
        XCTAssertEqual(number(fields["peak_total_power_ms2"]), 2500)
        let recent = list(await tool(registry, "get_hrv", #"{"which":"recent","period":"all_time"}"#))
        XCTAssertTrue(recent.contains { number($0["peak_rmssd_ms"]) == 81 }, "the per-period list carries peak capacity too")
    }

    // MARK: - Sleep record: bedtime, fell asleep, wake time

    func testTheSleepRecordCarriesBedtimeWakeTimeAndTheHeartRateSleepRead() async throws {
        let registry = try makeRegistry()
        let fields = record(await tool(registry, "get_sleep", #"{"which":"by_date","date":"\#(day)"}"#))
        XCTAssertEqual(time(fields["in_bed_start_iso"]), nightStart.addingTimeInterval(300))
        XCTAssertEqual(time(fields["sleep_start_iso"]), nightStart.addingTimeInterval(900))
        XCTAssertEqual(time(fields["sleep_end_iso"]), nightStart.addingTimeInterval(7 * 3600))
        XCTAssertEqual(number(fields["core_minutes"]), 250)
        XCTAssertEqual(number(fields["nap_minutes"]), 25)
        XCTAssertEqual(number(fields["segment_count"]), 1)
        XCTAssertEqual(number(fields["avg_sleep_rmssd_ms"]), 48)
        XCTAssertEqual(number(fields["min_sleep_hr_bpm"]), 47)
        XCTAssertEqual(number(fields["avg_sleep_hr_bpm"]), 55)
        XCTAssertEqual(number(fields["restorative_minutes"]), 120)
        XCTAssertEqual(number(fields["restorative_ratio"]), 0.3)
        let description = try XCTUnwrap(registry.namespaces.flatMap(\.entries).first { $0.display.hasPrefix("sleep.by_date(") }?.entryDescription)
        for word in ["bedtime", "wake time", "fell asleep"] {
            XCTAssertTrue(description.contains(word), "sleep.by_date must say it answers '\(word)'")
        }
    }

    // MARK: - Recovery: a night without a score keeps its feeling

    func testANightWithoutAScoreStillGivesItsMorningFeelingAndNotes() async throws {
        let registry = try makeRegistry()
        let fields = record(await tool(registry, "get_recovery", #"{"which":"by_date","date":"\#(partialDay)"}"#))
        XCTAssertNil(fields["score"], "an unscored night has no score")
        XCTAssertEqual(number(fields["morning_feeling"]), 2)
        guard case let .list(tags) = fields["morning_feeling_tags"] else { return XCTFail("the tags must be listed") }
        XCTAssertEqual(tags.compactMap(text), ["infection"])
        XCTAssertEqual(text(fields["notes"]), "Felt feverish")
        XCTAssertEqual(flag(fields["reliable_for_trends"]), false)
        XCTAssertEqual(text(fields["data_quality"]), "preSleep")
    }

    // MARK: - Recovery: the stored breakdown

    func testTheBreakdownSaysWhyTheScoreWasLow() async throws {
        let registry = try makeRegistry()
        let fields = record(await lookup(registry, "recovery.breakdown.by_date(\(day))"))
        XCTAssertEqual(number(fields["tier"]), 3)
        XCTAssertEqual(number(fields["composite_score"]), 54.5)
        XCTAssertEqual(flag(fields["spo2_penalty_applied"]), true)
        let factors = list(fields["factors"])
        XCTAssertEqual(factors.count, 3)
        let hrv = try XCTUnwrap(factors.first { text($0["label"]) == "HRV" })
        XCTAssertEqual(try XCTUnwrap(number(hrv["contribution"])), 30, accuracy: 0.001)
        XCTAssertEqual(text(hrv["impact"]), "negative")
        guard case let .list(penalties) = fields["penalties"] else { return XCTFail("penalties must be a list") }
        XCTAssertEqual(penalties.count, 1)
        let score = record(await tool(registry, "get_recovery", #"{"which":"by_date","date":"\#(day)"}"#))
        XCTAssertEqual(number(score["score_tier"]), 3)
        XCTAssertEqual(list(score["factor_scores"]).count, 3)
        let found = registry.entries(matching: "why was my recovery score low on february 20", limit: CompactToolRouter.findDataLimit).map(\.display)
        XCTAssertTrue(found.contains { $0.hasPrefix("recovery.breakdown.by_date") }, "find_data must find the breakdown: \(found)")
    }

    // MARK: - The night's heart-rate curve

    func testTheTimelineGivesHeartRateAtATimeOfNight() async throws {
        let registry = try makeRegistry()
        let fields = record(await lookup(registry, "hrv.timeline.by_date(\(day))"))
        XCTAssertEqual(number(fields["bucket_minutes"]), 5)
        let buckets = list(fields["buckets"])
        XCTAssertEqual(buckets.count, 12, "an hour of beats in five-minute buckets")
        XCTAssertEqual(time(buckets.first?["time_iso"]), nightStart)
        XCTAssertEqual(number(buckets.first?["hr_bpm"]), 60)
        let late = try XCTUnwrap(buckets.first { time($0["time_iso"]) == nightStart.addingTimeInterval(40 * 60) })
        XCTAssertEqual(number(late["hr_bpm"]), 50)
        XCTAssertEqual(number(late["rmssd_ms"]), 20)
        let found = registry.entries(matching: "what was my heart rate at 3am", limit: CompactToolRouter.findDataLimit).map(\.display)
        XCTAssertTrue(found.contains { $0.hasPrefix("hrv.timeline.by_date") }, "find_data must find the timeline: \(found)")
    }

    // MARK: - Every reading of a day

    func testEveryReadingOfADayIsReachableIncludingUnreliableOnes() async throws {
        let registry = try makeRegistry()
        let readings = list(await lookup(registry, "hrv.readings.by_date(\(day))"))
        XCTAssertEqual(readings.map { text($0["session_type"]) }, ["overnight", "nap", "quick"])
        guard readings.count == 3 else { return }
        XCTAssertEqual(number(readings[1]["rmssd_ms"]), 62)
        XCTAssertEqual(flag(readings[0]["reliable_for_trends"]), true)
        XCTAssertEqual(flag(readings[2]["reliable_for_trends"]), false)
    }

    // MARK: - Every returned field is named

    private func fieldNames(_ value: FactValue) -> Set<String> {
        switch value {
        case let .record(fields): Set(fields.keys)
        case let .list(items): items.reduce(into: Set<String>()) { $0.formUnion(fieldNames($1)) }
        default: []
        }
    }

    func testEveryNewLookupNamesEveryFieldItReturns() async throws {
        let registry = try makeRegistry()
        let keys = [
            "hrv.by_date(\(day))", "hrv.recent(all_time)", "hrv.timeline.by_date(\(day))", "hrv.readings.by_date(\(day))",
            "sleep.by_date(\(day))", "sleep.recent(all_time)", "recovery.score.by_date(\(day))", "recovery.score.by_date(\(partialDay))",
            "recovery.score.recent(all_time)", "recovery.breakdown.by_date(\(day))", "hrv.latest", "sleep.latest"
        ]
        for key in keys {
            let stem = String(key[..<(key.firstIndex(of: "(") ?? key.endIndex)])
            let entry = try XCTUnwrap(
                registry.namespaces.flatMap(\.entries).first { $0.display == stem || $0.display.hasPrefix(stem + "(") }, "\(stem) is not in the catalog"
            )
            let fields = fieldNames(await registry.resolveAsync(key))
            XCTAssertFalse(fields.isEmpty, "\(key) returned nothing for the seeded archive")
            for field in fields {
                XCTAssertTrue(entry.entryDescription.contains(field), "\(stem) returns \(field) but its description never names it")
            }
        }
    }
}
