@testable import Emuqu
import XCTest

/// Sample data must be enough nights to reach a real score, must look like a
/// few weeks of sleep rather than noise, and must come out again without touching
/// anything else. The removal tests are the ones that matter most: a reviewer
/// taps "Remove sample data" once, a real user might tap it with months of
/// their own recordings in the archive.
@MainActor
final class DemoSessionSeederTests: XCTestCase {
    private lazy var archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DemoSessionSeederTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: archiveDirectory)
    private let calendar = Calendar.current

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: archiveDirectory)
        } catch {
            // Nothing was written by this test.
        }
        try await super.tearDown()
    }

    /// Noon today: this morning's wake time has passed whatever the jitter.
    private var noonToday: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    // MARK: - Plans

    func testPlansAreConsecutiveNightsEndingThisMorning() {
        let now = noonToday
        let plans = DemoSessionSeeder.nightPlans(now: now, calendar: calendar)

        XCTAssertEqual(plans.count, DemoSessionSeeder.defaultNightCount)
        XCTAssertGreaterThanOrEqual(plans.count, 14, "Fewer than 14 nights never clears the baseline gate")
        XCTAssertEqual(plans.map(\.index), Array(0 ..< plans.count), "Oldest first")
        XCTAssertTrue(calendar.isDate(plans[plans.count - 1].end, inSameDayAs: now), "Newest night is last night")
        for (earlier, later) in zip(plans, plans.dropFirst()) {
            let gap = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: earlier.end), to: calendar.startOfDay(for: later.end)
            )
            XCTAssertEqual(gap.day, 1, "Night \(later.index) does not follow night \(earlier.index)")
            XCTAssertLessThan(earlier.end, later.start, "Nights overlap")
        }
        for plan in plans {
            XCTAssertLessThan(plan.end, now)
            XCTAssertTrue((6 * 3600 ... 9 * 3600).contains(plan.duration), "Night \(plan.index) lasts \(plan.duration / 3600) h")
        }
    }

    func testPlansStepBackADayBeforeThisMorningsWake() throws {
        let earlyMorning = try XCTUnwrap(calendar.date(bySettingHour: 4, minute: 0, second: 0, of: Date()))
        let plans = DemoSessionSeeder.nightPlans(now: earlyMorning, calendar: calendar)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: earlyMorning))

        XCTAssertEqual(plans.count, DemoSessionSeeder.defaultNightCount)
        XCTAssertTrue(plans.allSatisfy { $0.end < earlyMorning }, "A night still in progress is not last night")
        XCTAssertTrue(calendar.isDate(plans[plans.count - 1].end, inSameDayAs: yesterday))
    }

    func testPlansTellAStoryRatherThanNoise() {
        let plans = DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar)
        let hard = plans.filter { !$0.tags.isEmpty }
        XCTAssertEqual(Set(hard.flatMap(\.tags)), [ReadingTag.alcohol, .lateMeal, .travel])
        XCTAssertTrue(hard.allSatisfy { $0.recovery < 0.25 }, "Tagged nights are the bad ones")

        let usual = plans.filter(\.tags.isEmpty)
        let early = usual.prefix(7).map(\.recovery).reduce(0, +) / 7
        let late = usual.suffix(7).map(\.recovery).reduce(0, +) / 7
        XCTAssertGreaterThan(late, early + 0.1, "Recovery should trend upward across the weeks")
    }

    // MARK: - Beats

    func testSyntheticNightIsDeterministicAndPhysiological() throws {
        let plan = try XCTUnwrap(DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar).last)
        let points = DemoSessionSeeder.syntheticNight(plan)

        XCTAssertEqual(points, DemoSessionSeeder.syntheticNight(plan), "Every device must see the same nights")
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(Double(last.t_ms + Int64(last.rr_ms)) / 1000, plan.duration, accuracy: 2)
        XCTAssertTrue(points.allSatisfy { (450 ... 1_500).contains($0.rr_ms) })
        let meanHR = 60_000 / (Double(points.map(\.rr_ms).reduce(0, +)) / Double(points.count))
        XCTAssertTrue((48 ... 75).contains(meanHR), "Mean HR \(meanHR)")
    }

    func testVitalsCompareEachNightWithTheWeekBefore() throws {
        let result = try cannedResult()
        let nights = (0 ..< 3).map { _ in
            HRVSession(id: UUID(), startDate: Date(), endDate: Date(), state: .complete, rrSeries: nil, analysisResult: result, artifactFlags: nil)
        }
        let withVitals = DemoSessionSeeder.withVitals(nights)

        XCTAssertNil(withVitals[0].vitalsSnapshot?.respiratoryRateBaseline, "No week before the first night")
        XCTAssertEqual(withVitals[2].vitalsSnapshot?.respiratoryRateBaseline, result.ansMetrics?.respirationRate)
        XCTAssertEqual(withVitals[2].vitalsSnapshot?.restingHeartRate, result.timeDomain.meanHR)
    }

    // MARK: - Seeding

    func testSeedArchivesEveryNightTaggedAndScoresThemInDateOrder() async throws {
        let plans = DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar)
        var finalizedStarts: [Date] = []
        var reports: [Int] = []

        let ids = try await DemoSessionSeeder.seed(
            plans, into: archive, pipeline: try stubPipeline(),
            finalize: { night in
                finalizedStarts.append(night.startDate)
                var scored = night
                scored.recoveryScore = 7
                return scored
            },
            progress: { built, _ in reports.append(built) }
        )

        XCTAssertEqual(ids.count, plans.count)
        XCTAssertEqual(finalizedStarts, plans.map(\.start), "Each night is scored against the nights before it")
        XCTAssertEqual(reports, Array(1 ... plans.count))
        let entries = archive.entries
        XCTAssertEqual(Set(entries.map(\.sessionId)), Set(ids))
        XCTAssertTrue(entries.allSatisfy { DemoSessionSeeder.isSampleData($0.tags) }, "Every sample night carries the Demo tag")
        XCTAssertTrue(entries.allSatisfy { $0.sessionType == .overnight && $0.recoveryScore == 7 })
        XCTAssertEqual(Set(entries.map { calendar.startOfDay(for: $0.endDate ?? $0.date) }).count, plans.count, "One night per date")
    }

    func testSeedLeavesANightThatHoldsARecordingAlone() async throws {
        let plans = DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar)
        let real = try archiveRealSession(start: plans[10].start.addingTimeInterval(1_800), hours: 6)

        let ids = try await DemoSessionSeeder.seed(
            plans, into: archive, pipeline: try stubPipeline(), finalize: { $0 }, progress: { _, _ in }
        )

        XCTAssertEqual(ids.count, plans.count - 1)
        XCTAssertFalse(ids.contains(real.id))
        let stored = try XCTUnwrap(archive.retrieve(real.id))
        XCTAssertEqual(stored.tags, real.tags, "The real recording is not tagged or merged")
        XCTAssertEqual(stored.rrSeries?.points, real.rrSeries?.points)
    }

    // MARK: - Removal

    func testRemovalDeletesOnlySampleNights() async throws {
        let plans = DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar)
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -60, to: noonToday))
        let untagged = try archiveRealSession(start: older, hours: 7)
        // A user's own tag that happens to be called "Demo": same name, its own id.
        let lookalike = try archiveRealSession(
            start: older.addingTimeInterval(86_400), hours: 7,
            tags: [ReadingTag(name: DemoSessionSeeder.demoTagName, colorHex: "#FF0000")]
        )
        let seeded = try await DemoSessionSeeder.seed(
            plans, into: archive, pipeline: try stubPipeline(), finalize: { $0 }, progress: { _, _ in }
        )

        let targets = DemoSessionSeeder.sampleSessionIds(in: archive.entries, seededIds: [])
        XCTAssertEqual(Set(targets), Set(seeded))
        let removed = DemoSessionSeeder.remove(targets, from: archive)

        XCTAssertEqual(Set(removed), Set(seeded))
        XCTAssertEqual(Set(archive.entries.map(\.sessionId)), [untagged.id, lookalike.id])
        XCTAssertEqual(try archive.retrieve(untagged.id)?.rrSeries?.points, untagged.rrSeries?.points)
        XCTAssertEqual(try archive.retrieve(lookalike.id)?.tags, lookalike.tags)
        XCTAssertTrue(seeded.allSatisfy { archive.wasIntentionallyDeleted($0) }, "Tombstoned, so a sync pull cannot restore them")
        XCTAssertTrue(DemoSessionSeeder.sampleSessionIds(in: archive.entries, seededIds: Set(seeded)).isEmpty)
    }

    func testRemovalFindsASeededNightWhoseTagWasEditedAway() async throws {
        let plans = Array(DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar).suffix(3))
        let seeded = try await DemoSessionSeeder.seed(
            plans, into: archive, pipeline: try stubPipeline(), finalize: { $0 }, progress: { _, _ in }
        )
        try archive.updateTags(seeded[0], tags: [])

        XCTAssertEqual(DemoSessionSeeder.sampleSessionIds(in: archive.entries, seededIds: []).count, 2)
        XCTAssertEqual(Set(DemoSessionSeeder.sampleSessionIds(in: archive.entries, seededIds: Set(seeded))), Set(seeded))
    }

    // MARK: - The real pipeline

    /// The nights the app actually builds: its own sleep estimator and window
    /// analysis. A bad night must read worse than a good one, or the sample has
    /// nothing to show.
    func testRealPipelineProducesScorableNightsWithSleep() async throws {
        let plans = DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar)
        let hard = try XCTUnwrap(plans.first { $0.tags.contains(.alcohol) })
        let good = try XCTUnwrap(plans.last)
        let pipeline = realPipeline()

        let hardNight = await DemoSessionSeeder.buildNight(hard, pipeline: pipeline)
        let goodNight = await DemoSessionSeeder.buildNight(good, pipeline: pipeline)

        for night in [hardNight, goodNight] {
            let result = try XCTUnwrap(night.analysisResult)
            XCTAssertTrue((20 ... 90).contains(result.timeDomain.rmssd), "RMSSD \(result.timeDomain.rmssd)")
            XCTAssertTrue((45 ... 80).contains(result.timeDomain.meanHR), "HR \(result.timeDomain.meanHR)")
            let sleep = try XCTUnwrap(night.sleepSnapshot, "The Sleep chip needs a snapshot")
            XCTAssertTrue((300 ... 500).contains(sleep.nightSleepMinutes), "Slept \(sleep.nightSleepMinutes) min")
            XCTAssertGreaterThan(sleep.deepSleepMinutes ?? 0, 0)
            XCTAssertGreaterThan(sleep.remSleepMinutes ?? 0, 0)
            XCTAssertNotNil(night.sleepStartMs)
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(goodNight.analysisResult?.timeDomain.rmssd),
            try XCTUnwrap(hardNight.analysisResult?.timeDomain.rmssd) + 10
        )
    }

    // MARK: - The library, end to end

    /// The whole round trip the Dashboard offers: three weeks of nights through
    /// the app's own scoring, enough for the hero score, then gone again —
    /// archive, iCloud and baseline — with a real recording untouched.
    func testLibraryLoadsScoredNightsAndRemovesExactlyThem() async throws {
        let collector = RRCollector(polarManager: PolarManager(), healthKit: HealthKitManager(), archive: archive)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DemoSessionSeederTests-\(UUID().uuidString)"))
        let cloud = CloudDeletions()
        var library = SampleDataLibrary(collector: collector) { await cloud.record($0) }
        library.defaults = defaults
        let real = try archiveRealSession(start: try XCTUnwrap(calendar.date(byAdding: .day, value: -60, to: Date())), hours: 7)
        let priorBaseline = collector.settingsManager.settings.baselineRMSSD
        collector.baselineTracker.reset()

        let added = try await library.load(nights: 15) { _, _ in }

        XCTAssertEqual(added, 15)
        XCTAssertTrue(library.isPresent)
        let sample = try archive.entries.filter { $0.sessionId != real.id }.map { try XCTUnwrap(archive.retrieve($0.sessionId)) }
        XCTAssertTrue(sample.allSatisfy { $0.recoveryScore != nil && $0.isReliableForHRVAggregates })
        XCTAssertTrue(sample.allSatisfy { $0.sleepSnapshot != nil && $0.vitalsSnapshot != nil })
        XCTAssertTrue(sample.allSatisfy { $0.notes == SampleDataLibrary.sampleNote })
        XCTAssertNotNil(DashboardSessionPolicy.latestOvernightScore(inEntries: archive.entries, calendar: calendar), "No hero score")
        XCTAssertTrue(collector.baselineTracker.hasValidBaseline)
        let scores = sample.sorted { $0.startDate < $1.startDate }.compactMap(\.recoveryScore)
        XCTAssertGreaterThan((scores.max() ?? 0) - (scores.min() ?? 0), 1.5, "Scores should vary night to night: \(scores)")

        let removed = try await library.remove()

        XCTAssertEqual(removed, added)
        XCTAssertFalse(library.isPresent)
        XCTAssertEqual(archive.entries.map(\.sessionId), [real.id])
        XCTAssertEqual(try archive.retrieve(real.id)?.rrSeries?.points, real.rrSeries?.points)
        XCTAssertEqual(collector.baselineTracker.daysCollected, 0, "The baseline must forget the sample nights")
        XCTAssertEqual(collector.settingsManager.settings.baselineRMSSD, priorBaseline)
        XCTAssertNil(defaults.data(forKey: SampleDataLibrary.ledgerKey))
        let sent = await cloud.waitForCount(added)
        XCTAssertEqual(Set(sent), Set(sample.map(\.id)), "Every sample night, and only those, is deleted from iCloud")
    }

    // MARK: - Settings search

    func testSettingsSearchFindsSampleData() {
        let entries = SettingsSearchIndex.entries(
            scrollToTopToken: UUID(), settingsManager: AppDependencies.current.app.settingsManager
        )
        let title = String(localized: "Sample data", bundle: LanguageManager.appBundle)
        for query in ["demo", "sample data", "no strap"] {
            XCTAssertTrue(entries.filter { $0.matches(query) }.contains { $0.title == title }, "\"\(query)\" does not find sample data")
        }
    }

    // MARK: - Helpers

    /// Records the iCloud deletions the library sends.
    private actor CloudDeletions {
        private var ids: [UUID] = []

        func record(_ id: UUID) {
            ids.append(id)
        }

        /// The deletions go out on a task of their own; wait for them.
        func waitForCount(_ count: Int) async -> [UUID] {
            for _ in 0 ..< 200 where ids.count < count {
                await sleepQuietly(20_000_000, context: "CloudDeletions.waitForCount")
            }
            return ids
        }
    }

    private func realPipeline() -> DemoSessionSeeder.NightPipeline {
        let ans = HRVAnalysisPipeline.ANSConfiguration(baselineRMSSD: 45, vo2Max: nil, trainingLoadAdjustment: 0)
        return DemoSessionSeeder.NightPipeline(analyze: { session in
            let pipeline = HRVAnalysisPipeline(
                artifactDetector: ArtifactDetector(), windowSelector: WindowSelector(), healthKit: MockHealthKitService()
            )
            return await pipeline.analyzeWithAutoWindow(
                session: session, sleepStartMs: session.sleepStartMs, wakeTimeMs: session.sleepEndMs,
                trainingContext: nil, ansConfig: ans
            )
        })
    }

    /// Fast stand-ins for the seeding tests, which are about counts, dates,
    /// tags and removal rather than the analysis itself.
    private func stubPipeline() throws -> DemoSessionSeeder.NightPipeline {
        let result = try cannedResult()
        return DemoSessionSeeder.NightPipeline(analyze: { _ in result }, estimateSleep: { _, _ in nil })
    }

    /// One real analysis of a short stretch of a sample night.
    private func cannedResult() throws -> HRVAnalysisResult {
        let plan = try XCTUnwrap(DemoSessionSeeder.nightPlans(now: noonToday, calendar: calendar).last)
        let points = Array(DemoSessionSeeder.syntheticNight(plan).prefix(3_000))
        let series = RRSeries(points: points, sessionId: UUID(), startDate: plan.start)
        let pipeline = HRVAnalysisPipeline(
            artifactDetector: ArtifactDetector(), windowSelector: WindowSelector(), healthKit: MockHealthKitService()
        )
        return try XCTUnwrap(pipeline.analyzeFullSeries(series: series, flags: Array(repeating: .clean, count: points.count)))
    }

    @discardableResult
    private func archiveRealSession(start: Date, hours: Double, tags: [ReadingTag] = [.morning]) throws -> HRVSession {
        let id = UUID()
        let points = createRealisticPoints(count: Int(hours * 3600 / 0.8))
        let session = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(hours * 3600), state: .complete,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil, tags: tags
        )
        _ = try archive.archive(session, skipSameNightMerge: true)
        return session
    }
}
