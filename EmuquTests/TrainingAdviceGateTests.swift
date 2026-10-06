@testable import Emuqu
import XCTest

/// The shared training advice gate (`TrainingAdviceGate`) and every surface
/// that words training advice.
///
/// The audit's scenarios (bugs/trend-load.md, load_gate_trace.py): a
/// consolidated, clean night with ACWR 1.6 and recovery 80 (CTL 40, ATL 64,
/// TSB −24), or ACWR 1.99 with recovery 92 and HRV 20 % over baseline, got
/// "Great day for high-intensity training", "This is a great day to push
/// yourself" and "Go hard", because the load check sat outside the push gate
/// and the recovery copy took no load input at all.
@MainActor
final class TrainingAdviceGateTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    /// Phrases that tell the user to train hard.
    private let pushPhrases = [
        "Go hard", "push yourself", "Great day for high-intensity", "green light is there",
        "today is the day", "great day for intense training", "you can push today", "Tier 1"
    ]

    private func assertNoPush(_ lines: [String], _ surface: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            for phrase in pushPhrases where text.localizedCaseInsensitiveContains(phrase) {
                XCTFail("\(surface) says \"\(phrase)\": \(text)", file: file, line: line)
            }
        }
    }

    // MARK: - Scenarios

    private struct Scenario {
        let name: String
        let acwr: Double
        let ctl: Double
        let recovery: Double
        let rmssd: Double

        var atl: Double { acwr * ctl }
        var tsb: Double { ctl - atl }
    }

    private let scenarios = [
        Scenario(name: "ACWR 1.6, recovery 80", acwr: 1.6, ctl: 40, recovery: 80, rmssd: 66),
        Scenario(name: "ACWR 1.99, recovery 92", acwr: 1.99, ctl: 40, recovery: 92, rmssd: 66)
    ]

    private func context(_ scenario: Scenario) -> TrainingContext {
        TrainingContext(
            atl: scenario.atl, ctl: scenario.ctl, tsb: scenario.tsb, yesterdayTrimp: 80,
            vo2Max: nil, daysSinceHardWorkout: 1, recentWorkouts: nil
        )
    }

    private func live(_ scenario: Scenario) -> TrainingLoadRegistry.TrainingLoad {
        TrainingLoadRegistry.TrainingLoad(
            atl: scenario.atl, ctl: scenario.ctl, tsb: scenario.tsb, acwr: scenario.acwr,
            todayTrimp: nil, provenance: .live(asOf: Date())
        )
    }

    /// A good night: strong vagal tone, DFA 0.95, LF/HF 1.2, window CV 0.04,
    /// consolidated.
    private func goodNight(rmssd: Double) -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 100, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_100, sdnn: rmssd * 1.2, rmssd: rmssd, pnn50: 35,
                sdsd: rmssd * 0.95, meanHR: 54, sdHR: 3, triangularIndex: 12
            ),
            frequencyDomain: FrequencyDomainMetrics(vlf: 500, lf: 800, hf: 667, lfHfRatio: 1.2, totalPower: 2_100),
            nonlinear: NonlinearMetrics(
                sd1: 32, sd2: 48, sd1Sd2Ratio: 0.67, sampleEntropy: 1.5,
                approxEntropy: 1.2, dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 80, pnsIndex: 1.5, snsIndex: -0.5, readinessScore: 8,
                respirationRate: 14, nocturnalHRDip: 12, daytimeRestingHR: 62, nocturnalMedianHR: 54
            ),
            artifactPercentage: 2, cleanBeatCount: 290, analysisDate: Date()
        )
        result.isConsolidated = true
        result.isOrganizedRecovery = true
        result.windowHRStability = 0.04
        return result
    }

    private func overnight(daysAgo: Double, rmssd: Double, recovery: Double?) -> HRVSession {
        let start = Date().addingTimeInterval(-daysAgo * 86_400 - 8 * 3_600)
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3_600),
            state: .complete, sessionType: .overnight, rrSeries: nil,
            analysisResult: goodNight(rmssd: rmssd), artifactFlags: nil
        )
        session.recoveryScore = recovery.map { $0 / 10 }
        return session
    }

    /// The morning steps, from the live load (Morning Results) or from the
    /// frozen context alone (the morning PDF and Flo's context).
    private func steps(_ scenario: Scenario, live useLive: Bool) -> [String] {
        let session = overnight(daysAgo: 0, rmssd: scenario.rmssd, recovery: scenario.recovery)
        let earlier = (1 ... 5).map { overnight(daysAgo: Double($0), rmssd: 55, recovery: 75) }
        let generator = AnalysisSummaryGenerator(
            result: session.analysisResult ?? goodNight(rmssd: scenario.rmssd), session: session,
            recentSessions: earlier,
            sleep: AnalysisSleepInput(
                totalSleepMinutes: 450, inBedMinutes: 480, deepSleepMinutes: 90,
                remSleepMinutes: 100, awakeMinutes: 20, sleepEfficiency: 94
            ),
            trainingContext: context(scenario),
            liveLoadSnapshot: useLive ? live(scenario) : nil,
            canonicalBaselineRMSSD: 55
        )
        return generator.generate().actionableSteps
    }

    private func strongBreakdown(composite: Double) -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = [
            RecoveryScoreCalculator.ScoreFactor(label: "HRV", detail: "", score: composite, weight: 0.6, impact: .positive),
            RecoveryScoreCalculator.ScoreFactor(label: "Sleep", detail: "", score: composite, weight: 0.25, impact: .positive),
            RecoveryScoreCalculator.ScoreFactor(label: "Vitals", detail: "", score: composite, weight: 0.15, impact: .positive)
        ]
        return RecoveryScoreCalculator.ScoreBreakdown(compositeScore: composite, tier: 3, factors: factors, penalties: [])
    }

    // MARK: - The gate

    func testGateLevels() {
        typealias Gate = TrainingAdviceGate
        XCTAssertEqual(Gate.level(.init(acwr: 1.6, ctl: 40, tsb: -24)), .easier)
        XCTAssertEqual(Gate.level(.init(acwr: 1.99, ctl: 40, tsb: -39.6)), .easier)
        XCTAssertEqual(Gate.level(.init(acwr: 1.45, ctl: 40, tsb: -10)), .holdPush, "1.3–1.5 is above the usual range")
        XCTAssertEqual(Gate.level(.init(acwr: 1.1, ctl: 40, tsb: -4)), .clear)
        XCTAssertEqual(Gate.level(.init(acwr: 1.2, ctl: 60, tsb: -16)), .easier, "TSB −15 or lower is heavy fatigue")
        XCTAssertEqual(Gate.level(.init(acwr: 1.6, ctl: 2, tsb: -1.2)), .clear, "the ratio is noise below the chronic-load threshold")
        XCTAssertEqual(Gate.level(.init(acwr: 1.0, ctl: 40, tsb: 0, monotony: 2.5, strain: 2_000)), .holdPush)
        XCTAssertEqual(Gate.level(.init(acwr: 1.0, ctl: 40, tsb: 0, monotony: 2.5, strain: 500)), .clear, "a light week of similar sessions")
        XCTAssertEqual(Gate.level(nil), .clear)
        XCTAssertFalse(Gate.allowsPush(recoveryScore: 92, load: .init(acwr: 1.99, ctl: 40, tsb: -39.6)))
        XCTAssertTrue(Gate.allowsPush(recoveryScore: 92, load: .init(acwr: 1.0, ctl: 40, tsb: 0)))
    }

    // MARK: - Every surface

    func testMorningStepsNeverPushUnderAHighLoad() {
        for scenario in scenarios {
            assertNoPush(steps(scenario, live: true), "Morning steps (live load), \(scenario.name)")
            assertNoPush(steps(scenario, live: false), "Morning steps (frozen load), \(scenario.name)")
        }
    }

    /// The control: the same night with a clear load still gets the push
    /// copy, so the test above is not passing on an empty list.
    func testMorningStepsStillPushOnAClearLoad() {
        let clear = Scenario(name: "ACWR 1.0, recovery 92", acwr: 1.0, ctl: 40, recovery: 92, rmssd: 66)
        XCTAssertTrue(steps(clear, live: true).contains { $0.contains("Great day for high-intensity") })
    }

    func testMorningStepsHoldThePushAboveTheUsualRange() {
        // CTL 30 keeps TSB at −13.5, above the heavy-fatigue line.
        let above = Scenario(name: "ACWR 1.45, recovery 85", acwr: 1.45, ctl: 30, recovery: 85, rmssd: 60)
        let lines = steps(above, live: true)
        assertNoPush(lines, "Morning steps, ACWR 1.45")
        XCTAssertTrue(lines.contains("Recent load is above average — listen to your body."), "\(lines)")
    }

    func testRecoveryCardMessageNeverSaysGoHardUnderAHighLoad() {
        for scenario in scenarios {
            let level = TrainingAdviceGate.level(.init(live: live(scenario)))
            let message = ScoreBreakdownCopy.message(for: strongBreakdown(composite: scenario.recovery), loadLevel: level)
            assertNoPush([message], "Recovery card, \(scenario.name)")
            XCTAssertTrue(message.contains("an easier session"), message)
        }
    }

    func testScoreDetailActionsNeverPushUnderAHighLoad() {
        for scenario in scenarios {
            var session = overnight(daysAgo: 0, rmssd: scenario.rmssd, recovery: scenario.recovery)
            session.trainingSnapshot = context(scenario)
            let view = RecoveryScoreDetailView(
                session: session, result: goodNight(rmssd: scenario.rmssd),
                recentSessions: [], baselineStats: nil, totalSessionCount: 6
            )
            assertNoPush(view.buildActions(), "Score detail \"What to do today\", \(scenario.name)")
        }
    }

    func testWorkoutReportTierNeverGoesHardUnderAHighLoad() {
        for scenario in scenarios {
            var workout = HRVSession(
                id: UUID(), startDate: Date(), endDate: Date().addingTimeInterval(1_800),
                state: .complete, sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
            )
            workout.trainingSnapshot = context(scenario)
            var night = overnight(daysAgo: 0, rmssd: scenario.rmssd, recovery: scenario.recovery)
            night.scoreBreakdown = strongBreakdown(composite: scenario.recovery)
            let report = HolisticDailyReport(
                workoutSession: workout, workoutTrack: [], overnightSession: night,
                userMaxHR: 190, userRestingHR: 50, userLTHR: 168, units: .metric
            )
            assertNoPush([report.combinedReadinessScore().tier], "Workout report tier, \(scenario.name)")
        }
    }

    func testTrainingReadinessNeverPushesUnderAHighLoad() {
        for scenario in scenarios {
            let load = TrainingAdviceGate.Load(context: context(scenario))
            for readiness in stride(from: 0.0, through: 10.0, by: 0.5) {
                assertNoPush([ReadinessScoring.readinessMessage(for: readiness, load: load)], "Readiness message, \(scenario.name)")
                XCTAssertNotEqual(ReadinessScoring.readinessLabel(for: readiness, load: load), "Ready", "\(scenario.name) at \(readiness)")
            }
        }
    }

    /// CTL 2.0, ATL 3.2: the ratio reads 1.6 on almost no training. The
    /// readiness model scores it Ready, and the message no longer contradicts
    /// that with "a lighter session".
    func testReadinessLabelAndMessageAgreeOnANovelLoad() {
        let load = TrainingAdviceGate.Load(acwr: 1.6, ctl: 2.0, tsb: -1.2)
        let readiness = ReadinessScoring.calculateReadiness(
            recoveryScore: 80, todayTrimp: 0, ctl: 2.0, atl: 3.2, acuteChronicRatio: 1.6
        ) / 10
        XCTAssertEqual(ReadinessScoring.readinessLabel(for: readiness, load: load), "Ready")
        XCTAssertFalse(ReadinessScoring.readinessMessage(for: readiness, load: load).contains("lighter session"))
    }

    /// Heavy accumulated fatigue on a new user's base: the readiness model
    /// still reads Ready, so the label is held at Moderate beside the
    /// "lighter session" message.
    func testReadinessLabelIsHeldBesideALighterSessionMessage() {
        let load = TrainingAdviceGate.Load(acwr: 7, ctl: 3, tsb: -18)
        XCTAssertEqual(ReadinessScoring.readinessLabel(for: 8.0, load: load), "Moderate")
        XCTAssertTrue(ReadinessScoring.readinessMessage(for: 8.0, load: load).contains("lighter session"))
    }

    func testLiveReadinessHeadlineNeverPushesUnderAHighLoad() {
        for scenario in scenarios {
            var morning = overnight(daysAgo: 0, rmssd: scenario.rmssd, recovery: scenario.recovery)
            morning.trainingSnapshot = context(scenario)
            let metrics = TrainingMetrics(
                atl: scenario.atl, ctl: scenario.ctl, tsb: scenario.tsb, dailyTrimp: [:],
                todayTrimp: 0, todayWorkouts: [], recentWorkouts: []
            )
            let live = LiveReadiness.compute(recoveryScore: scenario.recovery, morningSession: morning, liveMetrics: metrics)
            assertNoPush([live.headline], "Live readiness headline, \(scenario.name)")
        }
    }
}
