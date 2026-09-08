@testable import Emuqu
import os
import XCTest

/// Tests for the AssistantContextBuilder - the function that turns live app
/// state into the AI Assistant's context payload.
///
/// These tests are hermetic: they pass in plain Swift values rather than
/// touching SettingsManager.shared, the on-disk session archive, or HealthKit.
final class AssistantContextBuilderTests: XCTestCase {
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
        // Pin to UTC so any date-bucketing logic (start-of-day, day windows)
        // produces the same results everywhere this test runs.
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Fixed UTC anchor — all dates derive from here so the suite is deterministic.
    private static let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession(
        id: UUID = UUID(),
        startOffset: TimeInterval = 0,
        sessionType: SessionType = .overnight,
        recoveryScore: Double? = nil,
        sleep: SleepData? = nil,
        training: TrainingContext? = nil,
        tags: [ReadingTag] = [],
        morningFeeling: Int? = nil,
        state: HRVSession.SessionState = .complete
    ) -> HRVSession {
        var session = HRVSession(
            startDate: Self.referenceNow.addingTimeInterval(startOffset),
            tags: tags,
            sessionType: sessionType
        )
        session.endDate = Self.referenceNow.addingTimeInterval(startOffset + 600)
        session.state = state
        session.recoveryScore = recoveryScore
        session.sleepSnapshot = sleep
        session.trainingSnapshot = training
        session.morningFeeling = morningFeeling
        return session
    }

    private func makeUserSettings() -> UserSettings {
        var s = UserSettings()
        // `age` is derived from `Date()` minus birthday, so we anchor 30 years
        // ago from "now" rather than from referenceNow.
        s.birthday = Calendar.current.date(byAdding: .year, value: -30, to: Date())
        s.biologicalSex = .male
        s.fitnessLevel = .moderatelyActive
        s.typicalSleepHours = 7.5
        return s
    }

    private func makeSleep() -> SleepData {
        SleepData(
            date: Self.referenceNow,
            totalSleepMinutes: 420,
            inBedMinutes: 460,
            deepSleepMinutes: 90,
            remSleepMinutes: 80,
            awakeMinutes: 20,
            sleepEfficiency: 0.91,
            boundarySource: .recordingBounds
        )
    }

    private func makeTraining() -> TrainingContext {
        TrainingContext(
            atl: 60,
            ctl: 50,
            tsb: -10,
            yesterdayTrimp: 75,
            vo2Max: 48,
            daysSinceHardWorkout: 2,
            recentWorkouts: nil
        )
    }

    // MARK: - Test 1: Required fields populated from session + settings

    func testBuildProducesExpectedTopLevelFields() {
        let settings = makeUserSettings()
        let today = makeSession(recoveryScore: 7.5)

        let context = ContextBuilder.build(
            latestSession: today,
            recentSessions: [today],
            userSettings: settings
        )

        // User profile
        XCTAssertNotNil(context.userProfile.age, "age should be derived from birthday")
        XCTAssertEqual(context.userProfile.biologicalSex, "Male")
        XCTAssertEqual(context.userProfile.fitnessLevel, "Moderately Active")
        XCTAssertEqual(context.userProfile.typicalSleepHours, 7.5)

        // Today's session present
        XCTAssertNotNil(context.today)
        XCTAssertEqual(context.today?.id, today.id)
        XCTAssertEqual(context.today?.recoveryScore, 7.5)
        XCTAssertEqual(context.today?.sessionType, "overnight")

        // Yesterday is nil when not provided
        XCTAssertNil(context.yesterday)
        XCTAssertNil(context.yesterdayDiagnostic)

        // Recent contains today
        XCTAssertEqual(context.recent.count, 1)
        XCTAssertEqual(context.recent.first?.recoveryScore, 7.5)
    }

    // MARK: - Test 2: Optional fields omitted when not available

    func testOptionalSleepAndTrainingAreOmittedWhenAbsent() {
        let settings = makeUserSettings()
        let session = makeSession(recoveryScore: 6.0) // no sleep, no training

        let context = ContextBuilder.build(
            latestSession: session,
            recentSessions: [session],
            userSettings: settings
        )

        XCTAssertNotNil(context.today)
        XCTAssertNil(context.today?.sleep, "Sleep snapshot should be omitted when no sleep data is attached")
        XCTAssertNil(context.today?.training, "Training snapshot should be omitted when no training data is attached")
        XCTAssertNil(context.today?.vitals, "Vitals snapshot should be omitted when no vitals data is attached")
        XCTAssertNil(context.analysisSummary, "Analysis summary should be omitted when analysisResult is nil")
        XCTAssertNil(context.baselines)
        XCTAssertNil(context.trends7Day)
        XCTAssertNil(context.trends30Day)
    }

    func testOptionalFieldsArePopulatedWhenAvailable() {
        let settings = makeUserSettings()
        let sleep = makeSleep()
        let training = makeTraining()
        let session = makeSession(recoveryScore: 8.0, sleep: sleep, training: training)

        let context = ContextBuilder.build(
            latestSession: session,
            recentSessions: [session],
            userSettings: settings
        )

        XCTAssertNotNil(context.today?.sleep)
        XCTAssertEqual(context.today?.sleep?.totalSleepMinutes, 420)
        XCTAssertEqual(context.today?.sleep?.deepSleepMinutes, 90)
        XCTAssertEqual(context.today?.sleep?.awakeMinutes, 20)

        XCTAssertNotNil(context.today?.training)
        XCTAssertEqual(context.today?.training?.atl, 60)
        XCTAssertEqual(context.today?.training?.ctl, 50)
        XCTAssertEqual(context.today?.training?.tsb, -10)
        XCTAssertEqual(context.today?.training?.daysSinceHardWorkout, 2)
    }

    // MARK: - Test 3: 14-day session window cap

    func testRecentSessionWindowIsCappedAt14() {
        let settings = makeUserSettings()
        // 20 sessions, one per day stretching back from the anchor.
        let sessions: [HRVSession] = (0 ..< 20).map { i in
            makeSession(startOffset: -Double(i) * 86400, recoveryScore: Double(i))
        }

        let context = ContextBuilder.build(
            latestSession: sessions.first,
            recentSessions: sessions,
            userSettings: settings
        )

        XCTAssertEqual(context.recent.count, 14, "Recent session list must be capped at 14 entries")
        // Newest first
        let dates = context.recent.map(\.date)
        let sortedDesc = dates.sorted(by: >)
        XCTAssertEqual(dates, sortedDesc, "Recent sessions should be sorted newest-first")
    }

    func testRecentSessionWindowFiltersIncompleteSessions() {
        let settings = makeUserSettings()
        let complete1 = makeSession(startOffset: 0, recoveryScore: 7, state: .complete)
        let collecting = makeSession(startOffset: -86400, recoveryScore: nil, state: .collecting)
        let complete2 = makeSession(startOffset: -2 * 86400, recoveryScore: 6, state: .complete)
        let paused = makeSession(startOffset: -3 * 86400, recoveryScore: 5, state: .paused)

        let context = ContextBuilder.build(
            latestSession: complete1,
            recentSessions: [complete1, collecting, complete2, paused],
            userSettings: settings
        )

        // Only complete + paused make it through
        XCTAssertEqual(context.recent.count, 3)
        XCTAssertFalse(context.recent.contains(where: { $0.recoveryScore == nil && $0.morningFeeling == nil }))
    }

    // MARK: - Test 4: Custom tag names propagate

    func testCustomTagNamesAreIncludedWhenPresent() {
        var settings = makeUserSettings()
        let custom = [
            ReadingTag(name: "Marathon Training", colorHex: "#112233"),
            ReadingTag(name: "Cycling Day", colorHex: "#445566")
        ]
        settings.customTags = custom
        let session = makeSession(recoveryScore: 7)

        let context = ContextBuilder.build(
            latestSession: session,
            recentSessions: [session],
            userSettings: settings,
            customTagNames: custom.map(\.name)
        )

        XCTAssertEqual(context.userProfile.customTagNames.sorted(), ["Cycling Day", "Marathon Training"])
    }

    func testCustomTagNamesAreEmptyByDefault() {
        let settings = makeUserSettings()
        let session = makeSession(recoveryScore: 7)

        let context = ContextBuilder.build(
            latestSession: session,
            recentSessions: [session],
            userSettings: settings
        )

        XCTAssertTrue(context.userProfile.customTagNames.isEmpty)
    }

    // MARK: - Edge cases

    func testNoSessionsProducesNilToday() {
        let settings = makeUserSettings()

        let context = ContextBuilder.build(
            latestSession: nil,
            recentSessions: [],
            userSettings: settings
        )

        XCTAssertNil(context.today)
        XCTAssertNil(context.yesterday)
        XCTAssertTrue(context.recent.isEmpty)
        // The user profile still renders with whatever the settings provide.
        XCTAssertNotNil(context.userProfile.age)
    }

    func testYesterdaySnapshotIncludedWhenProvided() {
        let settings = makeUserSettings()
        let today = makeSession(startOffset: 0, recoveryScore: 7)
        let yesterday = makeSession(startOffset: -86400, recoveryScore: 6)

        let context = ContextBuilder.build(
            latestSession: today,
            yesterdaySession: yesterday,
            recentSessions: [today, yesterday],
            userSettings: settings
        )

        XCTAssertNotNil(context.yesterday)
        XCTAssertEqual(context.yesterday?.id, yesterday.id)
        XCTAssertEqual(context.yesterday?.recoveryScore, 6)
    }

    // MARK: - Cloud live-state pushes today's facts (2026-08 regression)

    /// With an EMPTY data block — today's recovery / HRV / sleep tool-only —
    /// a model that doesn't reliably call tools (e.g. Grok) answers "I don't
    /// have that" even with a reading present. `renderLiveStateForCloud()`
    /// leads with today's high-value facts so "how am I / why did my HRV drop
    /// last night" is answerable with no tool call.
    func testCloudLiveStatePushesTodaysRecoveryHRVAndSleep() {
        let settings = makeUserSettings()
        let timeDomain = TimeDomainMetrics(
            meanRR: 60000.0 / 55.0, sdnn: 62, rmssd: 48, pnn50: 20,
            sdsd: 43, meanHR: 55, sdHR: 5, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: nil,
            approxEntropy: nil, dfaAlpha1: nil, dfaAlpha2: nil, dfaAlpha1R2: nil
        )
        let analysis = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: Self.referenceNow
        )
        var today = HRVSession(
            id: UUID(), startDate: Self.referenceNow,
            endDate: Self.referenceNow.addingTimeInterval(28800),
            state: .complete, sessionType: .overnight, rrSeries: nil,
            analysisResult: analysis, artifactFlags: nil, recoveryScore: 8.1
        )
        today.sleepSnapshot = makeSleep()
        today.trainingSnapshot = makeTraining()

        let context = ContextBuilder.build(
            latestSession: today, recentSessions: [today], userSettings: settings
        )
        let cloud = context.renderLiveStateForCloud()

        XCTAssertTrue(cloud.contains("TODAY:"), "cloud live-state must lead with today's facts — got: \(cloud)")
        XCTAssertTrue(cloud.contains("recovery 8.1/10"), "must include today's recovery — got: \(cloud)")
        XCTAssertTrue(cloud.contains("RMSSD 48.0"), "must include today's HRV (the exact thing that failed) — got: \(cloud)")
        XCTAssertTrue(cloud.contains("sleep 7h0m"), "must include today's sleep — got: \(cloud)")
    }

    // MARK: - Generated capability index (progressive-disclosure menu)

    /// The index is generated from the real read-tool catalog, so it can't
    /// drift from what the model can actually call, and it carries the hard
    /// "call the tool before denying data" instruction that stops the
    /// "I don't have that" failure.
    @MainActor
    func testCapabilityIndexListsCoreDataToolsAndInstructsToolUse() {
        let index = CompactToolRouter.capabilityIndex()
        for tool in ["get_recovery", "get_hrv", "get_sleep", "get_vitals", "get_training_load", "get_workout"] {
            XCTAssertTrue(index.contains(tool), "capability index must list \(tool) — got:\n\(index)")
        }
        XCTAssertTrue(index.contains("CALL the matching tool"),
                      "index must instruct the model to call the tool before answering")
        XCTAssertTrue(index.contains("Never claim you don't have the data"),
                      "index must forbid denying data without a tool call")
    }

    /// The index must actually reach the model — injected into the cached
    /// system prefix on tool-capable providers.
    @MainActor
    func testToolModePromptInjectsCapabilityIndex() {
        let composed = AssistantSystemPrompt.composeSplit(
            userFacts: "", priorSummary: nil, contextRendered: "", toolMode: true
        )
        XCTAssertTrue(composed.stable.contains("# What you can retrieve (data tools)"),
                      "tool-mode system prompt must include the generated capability index")
        XCTAssertTrue(composed.stable.contains("get_hrv"),
                      "the index in the prompt must list the HRV tool")
    }

    @MainActor
    func testNonToolModePromptOmitsDataToolIndex() {
        let composed = AssistantSystemPrompt.composeSplit(
            userFacts: "", priorSummary: nil, contextRendered: "", toolMode: false
        )
        XCTAssertFalse(composed.stable.contains("# What you can retrieve (data tools)"),
                       "non-tool providers shouldn't get the data-tool index")
    }
}
